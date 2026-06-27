# `Dust.once` / Coordinated Single-Flight — Behaviour Spec

**Date:** 2026-06-27
**Status:** Proposal / for discussion (not triaged)
**Source:** `rtsrc` adopter
**Related:** `2026-06-27-adopter-feedback-single-flight-coordination.md`
(the triage of which asked for "a separate lease design with fencing
tokens before adding leases or `Dust.once/3`" — this is that spec, from
the adopter's side: the exact behaviour we'd want, written as a contract).

## Purpose

Specify the precise behaviour of a coordinated distributed cache-fill
primitive: *for key `K`, one caller fills the value while every other
caller gets the result, with explicit, bounded behaviour on every failure
edge.* This is the negative space of the adopter's two use cases (Apify FB
polls, PDF OCR). It is **not** a request to ship as-is — it is the
behaviour the adopter would build against, so the Dust team can judge the
primitive against concrete semantics rather than a name.

## Naming caveat (read first)

The name `once` oversells it. Given the mandatory fallback path (below),
this is **coordinated single-flight while Dust is reachable**, which is
**at-least-once overall**, *not* exactly-once side-effect execution.
Recommend naming it `Dust.single_flight` / `Dust.coalesce` and reserving
`once` only for a variant that can never silently degrade. Docs must not
imply exactly-once.

## Signature

```elixir
Dust.once(store, key, opts, fun) ::
    {:ok, value, %{source: source, age_ms: non_neg_integer, fence: term}}
  | {:error, reason}

# source :: :cached | :computed | :awaited | :stale | :computed_uncoordinated
```

### Opts

- `fresh_for:` — value TTL. `:infinity` = **presence mode** (key exists ⇒
  done forever; PDF). A duration = **freshness mode** (refill if the
  result is older than this; FB ~1h).
- `lease_ttl:` — max time a fill may run before the **server** presumes
  the holder dead and allows re-election. Distinct from `fresh_for`.
  (FB ~5 min, OCR ~20 min.)
- `wait_timeout:` — max a follower (lease loser) blocks awaiting the
  winner's result.
- `on_unavailable: :run_local | :error` — behaviour when Dust can't be
  reached. Scraping uses `:run_local` (never block).

The **two-TTL split is load-bearing** and easy to conflate: `fresh_for`
governs *reuse of a finished result*; `lease_ttl` governs *liveness of an
in-progress fill*. They answer different questions and must both exist.

## Algorithm (exact)

1. **Fast path, local-only.** Read the **local materialized cache** for
   `key`. Presence mode: exists ⇒ return `{:ok, value, :cached}`.
   Freshness mode: `age < fresh_for` ⇒ return `{:ok, value, :cached}`.
   **No network.** This must be the common case.
2. **In-node single-flight.** If this node already has an in-flight
   `once` for `key`, the new caller joins it (one claim, one `fun` run,
   shared result) rather than racing its own claim.
3. **Claim.** Atomically try to become filler via `put_new`/lease,
   receiving a **fence token** = a monotonic generation id from the
   server. Server-authoritative time (no client clocks).
4. **Won ⇒ compute.** Run `fun`. On success, **publish guarded by the
   fence**: the write lands only if this fence is still the current
   holder. Return `{:ok, value, :computed, fence}`.
5. **Lost ⇒ await.** See "Contested lease" below.

## Contested lease — what the loser gets

The loser **never runs `fun`** on the happy path. It blocks on its
**local cache updating** (it subscribed; the winner publishes; the server
broadcasts; the loser's `SyncEngine` writes the value locally; the wait
wakes and reads it) — same local read path as everything else, no hotpath
HTTP.

**Generation-matched await (critical).** In freshness mode the loser
contested *because* it judged the current value stale. It must therefore
await a value **newer than the staleness cutoff that triggered its claim**
(generation > the stale one), not merely "any value present" — otherwise
it instantly "succeeds" by re-reading the stale value and the refill is
pointless. Presence mode: the condition is simply "key now exists."

| While awaiting… | Loser gets |
|---|---|
| Winner succeeds within `wait_timeout` | `{:ok, winner_value, :awaited}` — the fresh result, no `fun` run. **Normal case.** |
| Winner still working, `wait_timeout` hit, **lease still valid** | Must not compute (validly held). Freshness mode: return last-known value tagged `:stale` if one exists; presence mode (no prior value): `{:error, :timeout}` → caller snoozes/retries. |
| Winner **fails / releases** lease | Release wakes waiters → loser re-enters claim; one waiter is **promoted to winner** and runs `fun`. A failed fill must not strand followers. |
| Winner's lease **expires (crash)** | Server frees it; a waiter claims a new generation and is **promoted**. Same as above, via timeout not explicit release. |
| **Dust unreachable** mid-await | `on_unavailable: :run_local` → stop waiting, run `fun` locally, `:computed_uncoordinated`. Never blocks forever. |

**The property that makes it correct.** A loser ends in exactly one of
three places: *gets the winner's value*, *gets promoted and computes it
itself*, or *degrades to uncoordinated local compute*. What it must
**never** do is *wait for the winner and then also independently fetch the
same thing* — that double-pays the exact cost being eliminated. Fencing +
generation-matched await is what guarantees that: ride the winner's
result, or take over the lease, never both.

## Guarantees vs explicit non-guarantees

**Guarantees (Dust reachable):**
- At most one `fun` runs per `(key, generation)` at a time.
- All concurrent callers observe the same published result.
- A stale/expired holder's late write **cannot** clobber a newer holder's
  result (fencing on publish).

**Non-guarantees (must be documented, not hidden):**
- **Not exactly-once side effects.** `lease_ttl` expiry mid-run ⇒ a second
  filler may start (two runs). Crash after side effects but before the
  fenced publish ⇒ re-run on next call. `on_unavailable: :run_local` ⇒
  multiple nodes may run uncoordinated.
- Net: at-least-once. `fun` **must be idempotent**.

## Other edge behaviour

| Situation | Wanted behaviour |
|---|---|
| `fun` raises / returns error | Release lease, **don't publish**, surface error to the caller that ran it. Followers' waits expire → one re-elects. One failure must not poison followers. |
| Crash after publish-enqueue | At-least-once: result may be lost from the store; followers time out and re-elect; `fun` re-runs. Acceptable iff `fun` idempotent. |
| Concurrent callers, same node | Coalesce to one fill (step 2). |
| Large result (OCR text) | `once` publishes **whatever `fun` returns** — caller returns a *pointer* (S3 key), not bytes. `once` makes no size assumption. |

## Caller obligations (the contract's other half)

Because it is at-least-once:
- `fun` **must be idempotent / safe to repeat**.
- the **published value should be lightweight** (pointer, not payload).
- **followers must apply the result idempotently** (upsert by stable id:
  `post_id`, `content_hash`).

`once` coordinates; it does not absolve the caller of idempotency.

## Dependencies on the lower primitives

This spec is a *composition* and cannot ship before:
- **Durable, non-blocking writes** — for the winner's publish and to avoid
  blocking on ack.
- **`put_new` / `if_absent`** — race-free claim of a missing key.
- **Server lease type with fencing tokens / generations** — the fence in
  steps 3–5, server-owned TTL/expiry, holder-crash handling, release
  idempotency. The contested-lease table above is effectively the lease
  type's acceptance criteria viewed from the caller.

## The two adopter use cases

```elixir
# FB — freshness mode; fun returns the post list it wrote to the store
Dust.once(store, "pages/#{slug}",
  [fresh_for: :timer.hours(1), lease_ttl: :timer.minutes(5), on_unavailable: :run_local],
  fn -> apify_poll(slug) end)

# PDF — presence mode; fun returns the manifest pointer (S3 keys); bytes stay in R2
Dust.once(store, "artifacts/#{hash}",
  [fresh_for: :infinity, lease_ttl: :timer.minutes(20), on_unavailable: :run_local],
  fn -> download_and_ocr(hash) end)
```

## The one property to optimize for

If only one thing survives review: **the already-fresh path is a pure
local read, and the degraded (Dust-unreachable) path never blocks.**
Everything else is correctness arranged around those two.
