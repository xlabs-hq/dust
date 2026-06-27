# rtsrc Consumer Sign-off — Lease + `single_flight`

**Date:** 2026-06-27
**Status:** Sign-off (consumer green-light)
**Reviewer:** rtsrc (the adopter who filed the original feedback)
**Reviewed at:** `1d77b19` (origin/master) — Elixir SDK
**Related:** `2026-06-27-lease-and-single-flight-design.md`,
`2026-06-27-dust-once-behaviour-spec.md`,
`2026-06-27-adopter-feedback-single-flight-coordination.md`

## Verdict

**Ship it.** The implementation is a faithful, careful realization of the
adopter contract, and in several places stronger than the spec asked for.
rtsrc is happy to consume it as-is.

## Better than the spec asked for

- **Heartbeat-renewed lease** (`renew` at `ttl/3`, `spawn_link`ed to the
  worker). The spec listed "lease expires mid-work → second run" as an
  unavoidable *non-guarantee*; the heartbeat turns it into a guarantee for
  the progressing-work case, and a dead `fun` cleanly stops renewals.
- **Monotonic fence + monotonic deadlines** (NTP-immune steal); `renew`
  rejects an expired lease even on a matching token — closes the
  stale-holder-overwrites-newer-holder hole at the root.
- **Separate `lock_key` (`_dust:sf/<key>`) from the value key** — the
  consumer's typed projection subscribes only to value keys, never to
  lease churn.
- **Subscribe to both keys before re-reading** in the await path — closes
  a lost-wakeup window the spec didn't even name. Loser invariant
  (`gets winner's value | promoted | degrades, never double-pays`) is
  implemented exactly, including predicate re-validation on each wake,
  jittered re-elect backoff, stale-serve on timeout (freshness mode), and
  `{:error, :timeout}` (presence mode).

## Deferrals — all four acceptable to rtsrc

- **In-node coalescing Registry** (perf): fine. rtsrc's same-key/same-node
  concurrency is low (one Oban job per source per FB cycle; a couple of
  posts may share a PDF hash). The distributed lease covers correctness;
  worst case is a few extra lease round-trips, never duplicate expensive
  work.
- **REST lease surface:** N/A — rtsrc is on the Elixir SDK.
- **Per-op ack timer:** fine. The one residual is a *mid-publish*
  disconnect (held the lease, then dropped during the fenced `put/4`),
  which blocks on the GenServer call timeout (~5 s) then errors and Oban
  retries. Rare and bounded.
- **Durable outbox** (the "foundation" rtsrc originally flagged): **happy
  to drop it.** `single_flight` subsumes the Oban `DustWriteWorker` rtsrc
  had planned, and at-least-once + idempotent self-heals a lost publish
  (followers re-elect, `fun` re-runs). A re-run is cheap for rtsrc: OCR
  short-circuits on `Storage.stat`/extract-gate, an FB re-poll is ~$0.08
  on a rare crash. Net simplification of the consumer design.

## Notes rtsrc carries on its own side (not Dust's problem)

1. **Failure classification.** rtsrc must map each failure deliberately: a
   gazette PDF 404 is *transient* in its domain (PDF appears later) →
   `{:abort, _}` + Oban snooze, **not** a published negative; an empty FB
   page is *definitive* → `{:publish, %{posts: [], fetched_at: now}}` so
   the freshness window holds. The `{:publish}`/`{:abort}` split is the
   right knob.
2. **Abort, don't raise, on transient errors** inside Oban workers — raise
   waits out heartbeat-death expiry before re-election; `{:abort, _}`
   releases the lease immediately.
3. **`fresh?` keeps `fetched_at` in the value** (caller-side predicate,
   caller clock vs writer's stored time) until `committed_at` exists.
   Seconds of skew against a 1 h window is negligible.

## Consumption

Pinned via git ref (`xlabs-hq/dust`, `sparse: "sdk/elixir"`, ref
`1d77b19`) until the Hex release with TS + Crystal parity lands, plus the
`synced_at` cache-column migration. API consumed: `Dust.single_flight/4`,
`Dust.lease/renew/release`, `put_new` — all present in the Elixir SDK at
this ref.

Green-light from the consumer. — rtsrc
