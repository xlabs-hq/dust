# Dust Lease + `single_flight` — Design

**Date:** 2026-06-27
**Status:** Approved for implementation (panel-reviewed: OTP + API lenses, both BLESS WITH CHANGES — changes folded in below)
**Source:** `2026-06-27-adopter-feedback-single-flight-coordination.md` (#2/#3),
`2026-06-27-dust-once-behaviour-spec.md` (adopter contract). Consumer: rtsrc
(dedupe Apify FB polls + PDF OCR across nodes/envs; retire the hand-rolled
S3 content-addressing).

## What we're building

Two layers:

1. **A server-enforced lease** — `lease`/`renew`/`release` + opt-in fenced
   writes. The Redis `SET NX PX` + check-and-del idiom, but with a
   **monotonic** fence token and server-owned TTL.
2. **`Dust.single_flight/4`** — coordinated cache-fill composed on top: one
   caller in the fleet computes a value while the rest reactively await the
   result. The durable, observable result is the product; the lease is
   plumbing. Honest framing: **at-least-once / single-flight while reachable,
   NOT exactly-once.** `fun` must be idempotent.

Lineage: k8s `Lease` objects (lease-as-entry + holder + generation),
groupcache (fill-once-share-many), durable execution (run-once-by-identity,
must be idempotent), content-addressed memoization (rtsrc's MCAS, retired).

## Lease model (lease-as-entry, as a typed value)

A lease occupies a key. Its value is a **typed value** —
`{"_type": "lease", holder, token, expires_at}` — so it flows through the
existing typed-value machinery (counters/sets/files) and is **not** shredded
by map-flattening. `token` = the acquire op's `store_seq`: globally
monotonic, **preserved across renew**, bumped only on a fresh acquire/steal.
`expires_at` and `token` are **server-stamped** (server clock + seq); the
client cannot supply them — so acquire/renew/release are **dedicated ops**
(`:lease`/`:renew`/`:release`), not overloaded `set`s.

Leases live at a **sidecar key**, separate from any data/result key. The
low-level API leases whatever key you pass; `single_flight` keeps the result
at `K` and the lease at a reserved sibling, so presence-mode reads of `K`
never observe a lease envelope.

### Lazy expiry + atomic steal

No background sweeper. `:lease` succeeds if the key is **absent OR holds an
expired lease**, evaluated inside the single-writer SQLite transaction
against the server clock — so two concurrent claims cannot both win, and an
expired lease is reclaimed without op-log churn for idle leases. Crash → no
renew → stealable at `expires_at`.

> Clock note: `expires_at` is persisted wall-clock; backward NTP corrections
> shift the deadline. Atomicity is exact (one writer); the *deadline* is only
> as good as the server clock. Accepted.

## Low-level API

```elixir
Dust.lease(store, key, ttl_ms \\ 30_000, holder \\ auto)
  :: {:ok, %Dust.Lease{key, token, holder, expires_at}}
   | {:error, :held}        # a live lease, held by someone else
   | {:error, :occupied}    # a non-lease value sits at key
   | {:error, :unavailable} # Dust unreachable (fails fast; see below)

Dust.renew(lease, ttl_ms \\ 30_000)
  :: {:ok, %Dust.Lease{}} | {:error, :not_held}  # expired OR stolen OR released

Dust.release(lease) :: :ok                        # idempotent, token-checked, never errors

# fencing — opt on every write verb:
Dust.put(store, path, value, fence: lease) :: :ok | {:error, :fenced}
```

- `%Dust.Lease{}` is a **snapshot capability handle**; authority lives on the
  server. Passing a released/expired struct to `fence:` yields
  `{:error, :fenced}`, never a silent success.
- `renew` rejects an expired lease even if the token matches (forces fresh
  acquire).
- `{:error, :fenced}` is documented on every write verb that accepts `fence:`.

## Fail-fast acked writes (load-bearing — see panel)

`GenServer.call` timeouts *exit* the caller; they never return a tuple. So
lease ops + the `single_flight` publish must:

1. Make the public→engine call with **`:infinity`** (the engine's own bound
   always wins).
2. **Synchronously** reply `{:error, :unavailable}` when
   `state.status != :connected` — never enter await-ack mode.
3. For connected-but-never-acked: arm a per-op
   `Process.send_after(self(), {:ack_timeout, client_op_id}, op_timeout)`;
   on fire, `GenServer.reply(from, {:error, :unavailable})` and drop the
   pending entry. (`pending_ops` gains a per-op timeout — net-new.)

This also fixes the original outbox-feedback's "acked write blocks to the
GenServer timeout on disconnect." The **durable** outbox (replay on
reconnect) stays deferred; only fail-fast is in scope here.

## `Dust.single_flight/4`

```elixir
Dust.single_flight(store, key, fun, opts \\ [])
  :: {:ok, %Dust.Flight{value, source, stale?, age_ms, fence, coordinated?}}
   | {:error, reason}

# source :: :cached | :computed | :awaited   (pure provenance)
# stale?, age_ms, coordinated? live in the struct, not in source
```

`fun` returns `{:publish, value} | {:abort, reason}` (explicit — a value that
*is* `{:error, _}` can still be published; caching negative results is a real
case). `{:abort, reason}` releases the lease and returns `{:error, reason}`
without publishing. A raised `fun` is **not rescued** (house rule); the
lease self-heals at `lease_ttl`, accelerated by the `:DOWN` monitor below.

### Opts

- `fresh_for:` — `:infinity` = **presence mode** (key exists ⇒ done; OCR) |
  duration = **freshness mode** (refill if older; FB ~1h). Age is computed
  from the shipped **`synced_at`** column — accurate to sync-lag, fine for
  coarse windows. `committed_at` is a later precision upgrade, not required.
- `lease_ttl:` — liveness of an in-progress fill (distinct from `fresh_for`).
- `wait_timeout:` — max a loser blocks awaiting the winner.
- `on_unavailable: :run_local | :error` — default `:run_local` (never block).

### Algorithm

1. **Fast path — pure local read of `K`** (no network). Presence: exists ⇒
   `:cached`. Freshness: `age_ms < fresh_for` ⇒ `:cached`. The common case.
2. **In-node coalescing.** A `Registry` (`:unique`) keyed by `{store, key}`
   fronts a **supervised ephemeral owner** process per in-flight key. First
   caller registers and becomes the owner; others monitor it and await its
   result (`:DOWN` → retry the register loop). Race-free; no check-then-start.
3. **Claim** the sidecar lease (fence token).
4. **Won ⇒ compute.** Run `fun`; on `{:publish, v}`, **fenced publish** of
   `v` to `K`; `release`; `{:ok, %Flight{source: :computed, fence: ...}}`.
5. **Lost ⇒ await, in the CALLER process** (never inside a SyncEngine call —
   deadlock): **subscribe to `K` → re-read local cache → if already satisfied
   return, else `receive` up to `wait_timeout`.** **Generation-matched:** in
   freshness mode the awaited value must have `seq >` the stale seq that
   triggered the claim (else the loser instantly re-reads the stale value).

### Contested-lease outcomes (= the lease type's acceptance criteria)

| While awaiting… | Loser gets |
|---|---|
| Winner publishes within `wait_timeout` | `:awaited` (the fresh value). Normal case. |
| Timeout, lease still valid | freshness: last value with `stale?: true`; presence (no prior value): `{:error, :timeout}`. |
| Winner releases / `{:abort}` | release wakes waiters → one is promoted to winner. |
| Winner crashes (lease expires) | server frees it; a waiter claims a new generation, promoted. |
| Dust unreachable mid-await | `on_unavailable: :run_local` → run locally, `coordinated?: false`. |

**Invariant:** a loser ends in exactly one of {gets winner's value, gets
promoted and computes, degrades to local}. **Never** waits-then-also-fetches
(that double-pays the cost being eliminated). Fencing + generation-matched
await guarantee it.

### Crash / leak handling (rescue-free)

- The ephemeral owner holds the lease; SyncEngine `Process.monitor`s it and
  on `:DOWN` issues a **fenced `release`** (idempotent) — bounds recovery
  well under `lease_ttl` without `try/rescue`.
- `CallbackRegistry` monitors subscriber pids and auto-unregisters on `:DOWN`
  so a crashed awaiting loser doesn't leak a subscription.

## Guarantees / non-guarantees

**Guarantees (Dust reachable):** at most one `fun` per `(key, generation)` at
a time; all concurrent callers observe the same published result; a
stale/expired holder's late write cannot clobber a newer holder's
(fencing on publish).

**Non-guarantees (documented, not hidden):** not exactly-once. `lease_ttl`
expiry mid-run, crash-before-publish, or `:run_local` ⇒ a second run. Net:
**at-least-once; `fun` MUST be idempotent**; published values should be
lightweight pointers; followers apply results idempotently (upsert by stable
id).

## capver / cross-SDK

Additive on **capver 3** (new ops + `fence` precondition; pre-launch, no
bump). The lease ops + fence land in Elixir, TS, and Crystal CLI (parity
rule); HTTP adopters (`dust_ecto`) acquire/renew/release via REST (pure TTL,
no connection binding). `single_flight` is SDK-side composition — Elixir
first; TS/CLI follow.

## Implementation order

**Phase 5 — lease type.**
- Server: `:lease`/`:renew`/`:release` ops; in-txn steal/expiry/fence
  validation in `Dust.Sync.Writer`; `"lease"` typed value; `:lease`-aware
  `Sync.write` taxonomy; WS + REST surface. Fail-fast acked-write path.
- Elixir SDK: `Dust.lease/renew/release`, `%Dust.Lease{}`, `fence:` opt,
  `server_event` clauses for the new ops, per-op ack timer.
- Tests; then TS + CLI parity.

**Phase 6 — `single_flight`.**
- Elixir SDK: `Registry` + `DynamicSupervisor` ephemeral owner, in-node
  coalescing, generation-matched caller-side await, `:DOWN`-fenced-release,
  `%Dust.Flight{}`, the `{:publish,_}|{:abort,_}` contract, two-TTL +
  `synced_at` freshness, `on_unavailable`.
- Tests; TS later.

## Out of scope

Durable async outbox (replay-on-reconnect; fail-fast is enough here),
`committed_at`, subtree leases, MCP surface, actor-per-key.

## Panel review v2 — adopted changes (single_flight)

A second panel (OTP / API / distributed-systems lenses) reviewed the
`single_flight` implementation plan and caught real mistakes. Adopted:

**Correctness:**
- **Heartbeat-renew the lease while `fun` runs** (~`lease_ttl/3`). Without it
  a multi-minute fill under a short TTL expires mid-run and a second node
  steals → double-pay. The whole point, defeated by a default. *(blocker)*
- **`CallbackRegistry` monitors subscriber pids** and auto-unregisters on
  `:DOWN`. The await leaks an ETS row + worker per crashed waiter otherwise;
  this is the only `rescue`-free cleanup. Prerequisite to single_flight.
- **Losers subscribe both `key` AND `lock_key`** and re-validate the
  predicate on every wake. `Process.monitor` fires only on crash; a clean
  `{:abort}`/release exits normally and writes `lock_key`, not `key` — so
  without the lock_key subscription an abort strands every waiter to
  `wait_timeout`. The release/expiry event re-elects them.
- **Freshness via a caller `fresh?:` predicate over the value**, not
  `synced_at`. `synced_at` is local-receive time: an offline-then-catch-up
  node stamps stale data as fresh and skips a needed refill. The predicate
  reads the value's own `produced_at`; fleet-correct, no `committed_at`.
  Drops `fresh_for: <duration>` and `age_ms`. Presence mode = no predicate.
- **Monotonic lease deadlines** (server). Wall-clock `expires_at` lets a
  forward NTP step expire a live lease early → premature steal → double-pay.
  The writer keeps in-memory monotonic deadlines (`acquired_mono + ttl`) for
  the steal/fence decision; SQLite keeps wall-clock `expires_at` for clients
  and as the post-restart fallback (a restarted writer conservatively treats
  unknown leases as wall-clock-bound).
- **Jittered backoff on re-election** — when a lease expires all waiters wake
  and re-claim the single SQLite writer at once.

**API (`fun` + return):**
- **`fun` receives the live lease**: `fun :: (%Dust.Lease{} | nil ->
  {:publish, value} | {:abort, reason})`. Fenced follow-up writes happen
  inside the held section. `nil` only on the degraded `:run_local` path.
- **`{:ok, %Dust.Flight{value, source, stale?, coordinated?}}`** — `fence`
  dropped from the struct (a returned lease is already released — footgun).
  `source ∈ :cached | :computed | :awaited`. `:computed` values are
  normalized through the codec so every source returns the same shape.
- **Caller decisions:** `on_unavailable: :run_local` stays the default (never
  block; with in-node coalescing it's pay-once-per-node, documented cost
  tradeoff; `:error` for cost-over-availability). Crash recovery is bounded
  by `lease_ttl` (caller-pid model; heartbeat keeps `lease_ttl` modest).

**Documented contract rules:** definitive negative ⇒ `{:publish, neg}`;
transient failure ⇒ `{:abort, reason}` (+ jittered re-election) — neither
poisons a key nor retry-storms the upstream. Published values MUST be
pointer-sized (no eviction yet; eviction owed eventually). Disconnect
mid-await applies `on_unavailable`. `mode: :committed` on the await
subscription is load-bearing (avoids false-wake on a rolled-back optimistic
write). Mailbox flushed + subscriptions removed on every await exit.

## Implementation order (revised)

- **5a — monotonic lease deadlines** (server hardening on the shipped lease).
- **5b — `CallbackRegistry` subscriber-pid monitoring** (prerequisite).
- **6 — `Dust.single_flight`** (Elixir SDK) with all of the above. ✅ shipped.
- TS + CLI lease parity; REST lease surface; per-op ack timer; in-node
  coalescing Registry (deferred optimization) — follow-ups.

### Phase 6 implementation notes (as shipped)

- Stored value is **JSON-encoded as a scalar leaf** (not a plain map) so
  Dust's map-flattening doesn't shred a pointer into a subtree; every reader
  decodes it, so all sources return the same shape.
- `fun :: (%Dust.Lease{} | nil -> {:publish, value} | {:abort, reason})`;
  a wrong return raises `ArgumentError`.
- Heartbeat is a `spawn_link`ed loop renewing at `lease_ttl/3`; a raised `fun`
  kills the linked heartbeat → renewals stop → lease expires at `lease_ttl`
  (the documented recovery bound, caller-pid model).
- Loser awaits **both** `key` (committed publish) and `lock_key` (a committed
  `:delete` = release/expiry → re-elect) via `monitor: true` subscriptions,
  re-validating the `fresh?` predicate on every wake; jittered backoff on
  re-election; mailbox flushed + unsubscribed on every exit.
- In-node coalescing Registry was **deferred** — the distributed lease already
  prevents duplicate *work* for all callers; the Registry only saves redundant
  lease round-trips among concurrent same-node callers (a perf optimization).
