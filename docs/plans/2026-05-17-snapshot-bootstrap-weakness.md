# Snapshot/bootstrap path weakness

**Status:** noted, no implementation planned yet.
**Origin:** discovered while tracing xlabs RAM-pressure feedback.
Unrelated to the prefix-subscription question but found alongside it
(see `2026-05-17-prefix-scoped-subscription.md`).

## The weakness

The SDK's snapshot ingest path (`sdk/elixir/lib/dust/sync_engine.ex:527`)
has two related problems on stores beyond trivial size:

```elixir
def handle_cast({:snapshot, snapshot}, state) do
  snapshot_seq = snapshot["snapshot_seq"]
  entries = snapshot["entries"]

  # Bulk replace cache with snapshot data
  Enum.each(entries, fn {path, %{"value" => value, "type" => type}} ->
    state.cache.write(state.cache_target, state.store, path, value, type, snapshot_seq)
  end)

  {:noreply, %{state | last_store_seq: snapshot_seq}}
end
```

### 1. Whole snapshot held in RAM as one frame

The WS connection delivers the snapshot as a single frame. By the time
this cast runs, the entire decoded payload is sitting in the
SyncEngine's mailbox heap, and remains there until the cast returns.
Peak RAM transient ≈ snapshot payload size for the duration of the
ingest loop. For a few-KB store that's noise; for a multi-MB store
that's a temporary spike on every connect *and every reconnect*.

### 2. Per-entry cache writes — no batching at bootstrap

`Enum.each` issues one `cache.write/6` call per entry. The cache
behaviour does have a `write_batch/3` callback, and `Dust.Cache.Ecto`
implements it — but the snapshot path doesn't use it. For
`Dust.Cache.Ecto` over Postgres, that's N round-trips for an
N-entry snapshot. That's an O(N) bootstrap cost that scales linearly
with store size and is paid every time a consumer reconnects without a
warm cache.

For `Dust.Cache.Memory` it's cheaper (every write is in-process), but
each one is still a GenServer call, so it's N×call-overhead.

## Why neither bites xlabs today

xlabs's per-site stores are small (KB) and consumers stay connected.
Bootstrap happens once per process lifetime; per-entry overhead is
swamped by everything else.

## Where it bites

- Any consumer with a store large enough that snapshot bytes are
  meaningful (multi-MB+).
- Any consumer that reconnects frequently (deploys, network blips,
  ephemeral worker processes).
- Specifically `Dust.Cache.Ecto` over Postgres at scale, because
  per-entry writes amplify into Postgres round-trips.

## Suggested fixes (in order of payoff vs. effort)

### A. Use `write_batch` on the snapshot path (easy)

`sync_engine.ex:527` should call `state.cache.write_batch/3` instead
of `Enum.each → cache.write`. The cache behaviour already supports
it; only the snapshot caller needs to change. This collapses N
Postgres round-trips into one batched insert for `Dust.Cache.Ecto`,
and N GenServer calls into one for `Dust.Cache.Memory`.

Possibly chunk into batches of, say, 1000 entries so a giant snapshot
doesn't produce one absurdly large INSERT. Tune empirically.

### B. Stream snapshot from the server (harder)

The wire protocol could deliver the snapshot as a stream of chunked
frames rather than one monolithic frame. The SDK's connection process
would forward each chunk to the SyncEngine as it arrives, and the
engine would write each chunk via `write_batch` then GC it.

This eliminates the RAM transient (peak ≈ chunk size, not snapshot
size) and lets the consumer start serving the in-scope portion before
the full snapshot finishes transferring (with appropriate care around
`catch_up_seq` semantics).

Requires:
- Protocol change: snapshot becomes a multi-frame sequence with a
  terminating "snapshot complete" marker.
- Server change: stream rows from the source store directly to the
  socket rather than materialising into one big payload.
- SDK change in every language: state machine for "snapshot in
  progress, accumulating chunks" vs. "snapshot done, ready for
  catch_up."

This is a bigger lift and a protocol bump (capver). Worth doing if/when
a consumer starts hitting the per-store size where it actually matters.

### C. Persist `last_store_seq` across snapshot+catch_up

Tangentially related: if the SDK persists `last_store_seq` durably
(e.g. in `Dust.Cache.Ecto`'s sentinel row), reconnects can skip the
snapshot entirely when the local cache is already at-or-near the
server's tip. There may already be partial machinery for this — the
`@seq_sentinel_path "_dust:last_seq"` constant in `cache/ecto.ex`
suggests intent. Worth a closer look: if it's wired through, then
reconnect cost for warm consumers is already amortised, and (A)+(B)
only matter for cold starts. If it isn't fully wired, that's a
separate fix worth more than (A) and (B) combined.

## Suggested next step

Cheapest meaningful fix: do (A) — switch the snapshot path to
`write_batch`. Maybe ~20 lines including chunking and a regression
test. No protocol change, no other-SDK coordination needed.

Verify (C) before committing to (B). If warm reconnect already skips
snapshot, the snapshot path is only cold-start cost and (A) alone may
be enough.
