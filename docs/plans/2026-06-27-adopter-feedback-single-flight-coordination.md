# Dust Adopter Feedback — Single-Flight Coordination

**Date:** 2026-06-27
**Status:** Triaged field feedback
**Source:** `rtsrc` integration (Phoenix/Elixir, `dust` SDK + `Dust.Cache.Ecto`)

## TL;DR

An adopter built a cross-environment "compute the expensive thing once
when coordination is available" layer on top of Dust v0.1 — two cases:
(a) dedupe Apify Facebook-page polls across prod+staging, (b) dedupe PDF
download+OCR across nodes. It works, but every hard part was hand-rolled
out of primitives Dust *almost* offers. Everything we built reduces to
one pattern Dust is well positioned to support:

> **coordinated distributed cache-fill** — for key `K`, one caller should
> fill the value while other callers wait for the result, with explicit
> fallbacks when Dust is unavailable.

Dust already has the four ingredients: reactive store (publish),
subscriptions (await), CAS `if_match` (claim), and — in Ecto mode — a
repo (durability). We're assembling them by hand in the application.
This doc proposes pushing the assembly down into Dust, as three layered
primitives plus two small enablers, sequenced so each stands alone.

**Triaged recommendation:** accept the problem and the lower-level
primitives. Do **not** market or design this as "exactly once" execution.
Dust can coordinate work while reachable, but the fallback-to-local path,
lease expiry, process crashes, and external side effects mean callers
still need idempotent result writes and domain-specific duplicate
tolerance. Ship `put_new` / `if_absent` and a durable async write outbox
first; require a separate lease design with fencing tokens before adding
leases or `Dust.once/3`.

## The use case (provenance)

The adopter scrapes sources whose expensive step should not run twice
when the coordination service is reachable:

- **Facebook (Apify):** prod and staging share one Apify key and a
  $29/mo hard cap. Both polling the same page = double spend. Want: one
  poll per page per freshness window, shared across envs.
- **Government PDFs (OCR):** content-addressed bytes already share one R2
  bucket across envs, so transport is solved — but nothing stops two
  nodes OCR'ing the same content-hash concurrently (wasted AI spend), and
  "is it done?" is an S3 HEAD instead of a local lookup.

Shape of the hand-rolled solution, per key:
1. read local projection → fresh/done? use it, do nothing.
2. else CAS-claim a lease on a `meta`/`manifest` key.
3. winner does the work, writes the result; losers wait for it.
4. if Dust is unreachable, fall back to doing the work locally
   (uncoordinated) so scraping never blocks.

Each numbered step hit a Dust gap. They map 1:1 onto the proposals below.

## What we hit, and what would have helped

### 1 — Durable, non-blocking writes (foundation)

**Gap.** `SyncEngine.pending_ops` is in-memory. Plain optimistic writes
such as `put/3` return immediately, but acked writes (`put/4`,
`delete/3`, `merge/4`, etc.) return `{:noreply}` from `handle_call` and
only reply on the server ack. So a CAS claim or other sync write while
disconnected **blocks until the GenServer call timeout, then the caller
exits**. A node restart also **drops** un-acked ops, so the global
picture can silently diverge. `pending_ops` is a *reconnect* buffer (it
does replay on `:set_status, :connected`), not a durable queue.

**Why it matters.** The "Dust down must never block scraping" rule forced
the adopter to wrap result writes in their own Oban job for durability
and non-blocking enqueue. That's re-implementing an outbox Dust should
own — especially since Ecto mode *already* depends on a repo.

**Sketch.** A `dust_outbox` table alongside `dust_cache` for persistent
cache adapters. `put(async: true)` persists the op and returns
immediately; a sender drains the outbox, records final ack/rejection
state, and replays on boot. Non-CAS idempotent writes only (see the CAS
tension below). This turns the existing volatile queue into a real
offline write queue and deletes the adopter's `DustWriteWorker`.

**Triage note.** The earlier `dust_ecto` design deferred a stronger
outbox because `pending_ops` survives normal connection restarts and no
real "writes lost" report existed. This adopter feedback is that report.

**Effort:** M. **Depends on:** nothing. **Broadly useful:** yes — every
Ecto-mode adopter benefits; no new semantics, just durability for a queue
that already exists.

### 2 — A server-enforced lease type (candidate, needs design)

**Gap.** We built a lease from `meta` + CAS `if_match` + a `lease_at`
wall-clock + a stale-lease steal rule + a per-layer timeout. This leans
on **every client's clock** and a hand-written steal race. Dust already
rejects "make clients hand-roll it" for concurrent semantics — counters
and sets are server-owned types for exactly this reason. Coordination is
the same story one level up.

**Why it matters.** A `lease`/`renew`/`release` type with **server-owned
TTL** makes the server the single source of truth for "who holds it and
until when" — no client clocks, no skew, no steal dance. It also resolves
the CAS-vs-outbox tension from #1: **lease claims stay synchronous**
(live-or-fall-back; a lease acquired late is meaningless), while
**result writes go through the durable outbox**.

**Sketch.** `Dust.lease(store, key, ttl_ms)` → `{:ok, token}` | `:held`;
`renew(token)`; `release(token)`. Server tracks holder + expiry, sweeps
on TTL. Composes with, but is cleaner than, raw CAS.

**Required before approval.** Write a separate lease design covering
fencing tokens / generations, stale holder behavior, renew timing,
holder crash, release idempotency, expiry broadcast, audit/log shape,
capver, REST/WS/MCP surface, and cross-SDK semantics. Without fencing, a
holder whose lease expires while work is still running can publish a
late result over a newer holder's work.

**Effort:** M/L (server state + expiry sweep + protocol/API design).
**Depends on:** enabler 4a (`put_new`/`if_absent`) unless the lease uses a
dedicated server-side table instead of map entries.

### 3 — `Dust.once/3` (defer)

**Gap.** Nothing — this is purely the composition of #1 + #2 +
subscriptions that the adopter wrote by hand, twice.

**Sketch.** `Dust.once(store, key, ttl, fn -> expensive() end)`: claim
the lease; if you won, run the fn, publish the result, return it; if you
lost, await the subscription and return the published result. Both
adopter use cases (FB poll, PDF OCR) could collapse to one call.

**Triage note.** Do not ship this until the lower primitives have real
use and the lease semantics are precise. The API name and docs must avoid
promising exactly-once side-effect execution; at best it is coordinated
single-flight while Dust is reachable.

**Effort:** S once #2 exists. **Depends on:** #1, #2.

## Two small enablers

### 4a — `put_new` / `if_absent` — approved next primitive

Claiming a key that **may not exist** is awkward with `if_match:
<revision>` (no revision yet). A first-class `put(..., if_absent: true)`
(a.k.a. `put_new`) makes claim-a-missing-key race-free and readable. It
is broadly useful beyond leases and fits the existing CAS model.

### 4b — Entry write-timestamp — shipped as `synced_at`

Freshness ("is my copy younger than X?") forced us to embed
`fetched_at` inside the value, because the cache row had no wall clock.
The approved **`synced_at`** design (2026-06-27) is implemented. It fixes
the cold-start / mirror-staleness question and is the right first
increment.

**One distinction worth flagging for the single-flight case:** `synced_at`
is *this mirror's* write time. The freshness *decision* in single-flight
wants the **writer's** time ("when did whoever filled this key fill it?"),
which is the same across mirrors. That's the server `committed_at` you
deliberately deferred. Until it exists, single-flight keeps a `fetched_at`
**in the value** (cheap, correct). When a second use case for authoritative
cross-mirror time appears, `committed_at` would let `Dust.once`'s freshness
check stop reading payload — i.e. it's the natural follow-up to `synced_at`,
not a competing idea.

## Recommended sequence

1. **Document shipped `synced_at` and the SDK signpost** — make it clear
   that hot-path local-cache reads use `dust` + a persistent cache adapter;
   `dust_ecto` HTTP mode is for stateless/low-frequency paths unless it is
   promoted to SDK mode.
2. **#4a `put_new` / `if_absent`** — small, generally useful, and the
   cleanest next concurrency primitive.
3. **#1 durable async outbox for non-CAS writes** — high leverage for
   Ecto-mode adopters; turns the existing volatile queue into a durable
   queue.
4. **Separate lease design** — include fencing tokens/generations and
   failure semantics before implementation.
5. **#2 server-enforced lease type** — implement only after the design is
   accepted.
6. **#3 `Dust.once`** — sugar after leases prove themselves in real use.
7. **`committed_at`** — only when a second real use case appears;
   `synced_at` is enough for now.

#1 and #4a are the concrete primitives missing when the adopter hit the
wall. #2 and #3 are plausible product APIs, but they should follow a
stronger semantics design rather than ship directly from this feedback
note.

## Notes for whoever picks this up

- The adopter's app-side design (typed projection tables fed by a
  subscription, lease + Oban result-writes, fall-back-to-local on Dust
  down) ships regardless — these proposals would *simplify* it, not block
  it. No urgency-driven coupling.
- Cross-SDK parity rule applies to anything touching the cache/outbox
  schema (Elixir Memory+Ecto, TS, Crystal CLI), same as `synced_at`.
- `dust_ecto` HTTP mode is the wrong tool for hot-path reads; the adopter
  is on `dust` + `Dust.Cache.Ecto` (local-cache reads). If using
  `dust_ecto` for an Ecto-shaped API, configure SDK mode for realtime and
  local-cache behavior.
