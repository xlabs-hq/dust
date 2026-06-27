# @dust-sync/sdk

TypeScript client for Dust reactive state sync. Connect to a store, read and write data, and subscribe to changes with glob-pattern callbacks.

## Installation

```bash
npm install @dust-sync/sdk
```

## Quick Start

```typescript
import { Dust } from "@dust-sync/sdk"

const dust = new Dust({
  url: "wss://your-host.com/ws/sync",
  token: "dust_tok_...",
})

// Write
await dust.put("org/store", "users/alice", { name: "Alice", role: "admin" })

// Read (instant, from local cache)
const user = await dust.get("org/store", "users/alice")

// Delete
await dust.delete("org/store", "users/alice")

// Subscribe to live changes
const unsub = dust.on("org/store", "users/*", (event) => {
  console.log(`${event.path} changed:`, event.value)
})

// Unsubscribe when done
unsub()
```

## API

### Reads

```typescript
// Get value (returns null if missing)
const value = await dust.get("org/store", "path")

// Get full entry with metadata
const entry = await dust.entry("org/store", "path")
// => { path, value, type, seq, syncedAt } | null
// syncedAt: local wall-clock (unix epoch ms) when this mirror last wrote
// the row from a sync event — use it to gauge how stale the local copy is.

// Batch read (up to 1000 paths)
const values = await dust.getMany("org/store", ["path.a", "path.b"])
// => { "path.a": ..., "path.b": ... }

// Enum with glob pattern
const entries = await dust.enum("org/store", "users/*")
// => Entry[]

// Paginated enum
const page = await dust.enum("org/store", "users/**", {
  limit: 20,
  order: "desc",
  select: "entries", // or "keys" or "prefixes"
})
// => { items: Entry[], nextCursor: string | null }

// Range read [from, to)
const range = await dust.range("org/store", "logs.2026-04-01", "logs.2026-04-30")
// => { items: Entry[], nextCursor: string | null }
```

### Writes

All writes return `Promise<{ storeSeq: number }>`.

```typescript
await dust.put("org/store", "key", value)
await dust.merge("org/store", "settings", { theme: "dark" })
await dust.delete("org/store", "key")
await dust.increment("org/store", "stats/views", 1)
await dust.add("org/store", "post.tags", "typescript")
await dust.remove("org/store", "post.tags", "draft")
```

### Compare-and-Swap

Pass `ifMatch` with the expected revision. Throws `ConflictError` if another write landed first:

```typescript
import { ConflictError } from "@dust-sync/sdk"

const entry = await dust.entry("org/store", "users/alice")
try {
  await dust.put("org/store", "users/alice", updated, {
    ifMatch: entry!.seq,
  })
} catch (err) {
  if (err instanceof ConflictError) {
    console.log("Conflict — current revision:", err.currentRevision)
  }
}
```

### Put-new (claim if absent)

Pass `ifAbsent: true` to write only when the key does not already exist —
a race-free claim. Throws `ExistsError` if another writer got there first:

```typescript
import { ExistsError } from "@dust-sync/sdk"

try {
  await dust.put("org/store", "locks/poll", nodeId, { ifAbsent: true })
  // won the claim
} catch (err) {
  if (err instanceof ExistsError) {
    // someone else holds it
  }
}
```

### Subscriptions

```typescript
// Live changes only
const unsub = dust.on("org/store", "posts/*", (event) => {
  // event: { storeSeq, op, path, value, deviceId, clientOpId }
})

// Watch with bootstrap — delivers cached entries as "present" events first
const unsub = await dust.watch("org/store", "posts/*", (event) => {
  if (event.op === "present") {
    // Initial cached entry: { op, path, value, type, seq }
  } else {
    // Live update: { storeSeq, op, path, value, deviceId, clientOpId }
  }
}, { limit: 100, order: "desc" })
```

### Coordination: leases & single-flight

`singleFlight` computes an expensive thing **once across your fleet** and
shares the result. **At-least-once while reachable, not exactly-once** — `fn`
must be idempotent and publish a small pointer.

```typescript
import { SingleFlightAbort } from "@dust-sync/sdk"

// Done-forever (presence mode):
const flight = await dust.singleFlight(store, `artifacts/${hash}`, async () => {
  const keys = await downloadAndOcr(hash)   // bytes stay in S3
  return { publish: { manifest: keys } }    // small pointer
}, { leaseTtl: 20 * 60_000 })               // heartbeat-renewed while it runs
flight.value // { manifest: [...] };  flight.source: 'cached'|'computed'|'awaited'

// Fresh-within-a-window (freshness mode): value carries its own timestamp.
await dust.singleFlight(store, `pages/${slug}`, async () => {
  return { publish: { posts: await poll(slug), fetchedAt: Date.now() } }
}, {
  fresh: (v) => Date.now() - v.fetchedAt < 60 * 60_000,
  leaseTtl: 5 * 60_000,
  onUnavailable: "runLocal",                // never block; pay-once-per-node if Dust is down
})
```

`fn` returns `{ publish: value }` or `{ abort: reason }`. Prefer `{ abort }`
over throwing for transient failures (it releases the lease immediately;
others re-elect at once). `singleFlight` rejects with `SingleFlightAbort`,
`SingleFlightTimeout`, or `LeaseError`.

The low-level lease is available directly too:

```typescript
const lease = await dust.lease(store, "jobs/nightly", { ttlMs: 60_000 })
if (lease) {
  await doWork()
  await dust.put(store, "jobs/nightly/result", result, { fence: lease }) // throws LeaseError('fenced') if lost
  await dust.release(store, lease)
} // lease === null → someone else holds it
```

### Connection

```typescript
const dust = new Dust({
  url: "wss://your-host.com/ws/sync",
  token: "dust_tok_...",
  format: "msgpack", // or "json" (default)
})

// Check connection status
const { connected, seq } = dust.status("org/store")

// Close when done
dust.close()
```

## Full Documentation

See the [main Dust README](../../README.md) for the complete API reference, type system, conflict resolution semantics, and architecture overview.
