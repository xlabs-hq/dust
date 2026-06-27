# Dust Recipes

Task-oriented patterns for common problems. These compose the primitives
documented in the [SDK READMEs](../../README.md#readme) and the
[API reference](https://dustlayer.io/api-docs); here we show *when* and *why*
to reach for each.

Examples are shown for the **Elixir** (`dust`) and **TypeScript**
(`@dust-sync/sdk`) SDKs. The Crystal CLI mirrors the low-level verbs
(`dust lease|renew|release`, `dust put --if-match|--if-absent`).

- [Compute something once across your fleet](#compute-something-once-across-your-fleet)
- [Run a job on exactly one node](#run-a-job-on-exactly-one-node)
- [Optimistic concurrency (compare-and-swap)](#optimistic-concurrency-compare-and-swap)
- [Claim a key once (put-new)](#claim-a-key-once-put-new)
- [Reason about freshness / staleness](#reason-about-freshness--staleness)
- [Page through a large collection](#page-through-a-large-collection)

---

## Compute something once across your fleet

**Problem:** an expensive, costly operation (an OCR run, a rate-limited API
poll) should happen **once** across prod + staging + N nodes, and the result
should be visible everywhere — without each node polling S3 or a database to
ask "is it done yet?".

**Use `single_flight`.** One caller computes; the rest reactively await the
published result. It is **at-least-once while Dust is reachable, not
exactly-once** — your `fn` must be idempotent and publish a *small pointer*
(keep the bytes in S3/your DB).

```elixir
# Done-forever (presence mode): OCR a PDF once per content hash.
{:ok, %Dust.Flight{value: manifest, source: source}} =
  Dust.single_flight(store, "artifacts/#{hash}", fn _lease ->
    {:ok, keys} = download_and_ocr(hash)   # bytes stay in R2
    {:publish, %{"manifest" => keys}}      # publish a small pointer
  end, lease_ttl: :timer.minutes(20))      # heartbeat-renewed while it runs

# source is :cached (fresh hit, no work), :computed (we ran it),
# or :awaited (another node ran it; we rode the result).
```

```typescript
// Fresh-within-a-window (freshness mode): poll a page at most hourly.
const flight = await dust.singleFlight(store, `pages/${slug}`, async () => {
  return { publish: { posts: await poll(slug), fetchedAt: Date.now() } }
}, {
  fresh: (v) => Date.now() - v.fetchedAt < 60 * 60_000,  // value carries its own time
  leaseTtl: 5 * 60_000,
  onUnavailable: "runLocal",   // never block; pay-once-per-node if Dust is down
})
```

**The two knobs that matter:**

- **Failure classification.** Return `{:publish, value}` for a *definitive*
  result (even an empty one — so the freshness window holds and you don't
  recompute); return `{:abort, reason}` for a *transient* failure (so it isn't
  cached). An empty page is definitive; a 404 that will appear later is
  transient.
- **Abort, don't raise**, for transient errors: `{:abort, _}` releases the
  lease immediately (waiters re-elect at once); a raised `fn` only frees the
  lease when `lease_ttl` expires.

> `fresh?`/`fresh` runs locally over the value, so carry a `fetched_at`/
> `fetchedAt` timestamp inside the published value (as above). Presence mode
> (no predicate) means "exists ⇒ done".

---

## Run a job on exactly one node

**Problem:** a periodic job (a nightly rebuild, a migration step) should run on
one node at a time, not all of them.

**Use the lease directly.** `lease` acquires (or steals an expired lease);
`fence:` guards your writes so a holder that lost the lease can't clobber a
newer one's work.

```elixir
case Dust.lease(store, "jobs/nightly", ttl_ms: 60_000) do
  {:ok, lease} ->
    result = rebuild()
    # Fenced: rejected with {:error, :fenced} if we lost the lease mid-run.
    :ok = Dust.put(store, "jobs/nightly/result", result, fence: lease)
    Dust.release(store, lease)

  {:error, :held} ->
    :someone_else_has_it
end
```

```typescript
const lease = await dust.lease(store, "jobs/nightly", { ttlMs: 60_000 })
if (lease) {
  const result = await rebuild()
  await dust.put(store, "jobs/nightly/result", result, { fence: lease }) // throws LeaseError('fenced') if lost
  await dust.release(store, lease)
} // lease === null → someone else holds it
```

For a long job, `renew` periodically (or just set a generous `ttl_ms`). Leases
expire lazily on the server's monotonic clock — a crashed holder is reclaimed
at `ttl_ms`, no sweeper, no client clocks.

---

## Optimistic concurrency (compare-and-swap)

**Problem:** two writers race to update the same entry and you must not lose an
update.

**Use `if_match` with the entry's revision.**

```elixir
{:ok, entry} = Dust.entry(store, "users/alice")

case Dust.put(store, "users/alice", updated, if_match: entry.revision) do
  {:ok, _seq}        -> :saved
  {:error, :conflict} -> :retry   # someone wrote first; re-read and retry
end
```

```typescript
import { ConflictError } from "@dust-sync/sdk"

const entry = await dust.entry(store, "users/alice")
try {
  await dust.put(store, "users/alice", updated, { ifMatch: entry!.seq })
} catch (err) {
  if (err instanceof ConflictError) { /* re-read and retry */ }
}
```

CAS is leaf-only. CLI: `dust put <store> <path> <json> --if-match N`.

---

## Claim a key once (put-new)

**Problem:** race-free "create this if it doesn't exist yet" — the
no-revision-yet case `if_match` can't express.

**Use `if_absent`.**

```elixir
case Dust.put(store, "locks/import-#{id}", node_id, if_absent: true) do
  {:ok, _seq}      -> run_import(id)            # we won the claim
  {:error, :exists} -> :already_claimed
end
```

```typescript
import { ExistsError } from "@dust-sync/sdk"

try {
  await dust.put(store, `locks/import-${id}`, nodeId, { ifAbsent: true })
  await runImport(id)                            // we won the claim
} catch (err) {
  if (err instanceof ExistsError) { /* already claimed */ }
}
```

The existence check is atomic on the server. HTTP: `If-None-Match: *`. CLI:
`dust put ... --if-absent`.

---

## Reason about freshness / staleness

**Problem:** "how old is my local copy of this key?" — e.g. to decide whether
to refetch from an upstream source.

Every cached row carries `synced_at` — the local wall-clock (unix epoch ms)
when this mirror last wrote the row from a sync event.

```elixir
{:ok, entry} = Dust.entry(store, "feeds/sports")
age_ms = System.system_time(:millisecond) - entry.synced_at
if age_ms > :timer.minutes(5), do: refresh()
```

```typescript
const entry = await dust.entry(store, "feeds/sports")
if (entry?.syncedAt && Date.now() - entry.syncedAt > 5 * 60_000) await refresh()
```

> `synced_at` is *this mirror's* receive time, accurate to sync lag — perfect
> for "how stale is my cache". For a freshness *decision shared across the
> fleet* (e.g. single-flight's `fresh?`), put the producer's timestamp inside
> the value instead, so every node agrees.

---

## Page through a large collection

**Problem:** a key namespace has thousands of entries and you need to list or
scan them without loading everything.

**Use paginated `enum` (glob) or `range` (lexicographic).** Both read the
local cache — no server round-trip.

```elixir
# Paginated glob enumeration.
page = Dust.enum(store, "posts/**", limit: 50, order: :desc)
page.items        # [%Dust.Entry{}, ...]
page.next_cursor  # opaque cursor, or nil

# Lexicographic range [from, to) — ideal for ULID/time-ordered keys.
page = Dust.range(store, "logs/2026-01-01", "logs/2026-02-01", limit: 100)
```

```typescript
const page = await dust.enum(store, "posts/**", { limit: 50, order: "desc" })
const range = await dust.range(store, "logs/2026-01-01", "logs/2026-02-01", { limit: 100 })
```

`select: :keys` / `:prefixes` project to path strings or unique immediate
prefixes when you don't need the values. CLI: `dust enum` / `dust range`.
