# TypeScript SDK + MessagePack Wire Format Design

A TypeScript client for Dust that connects via WebSocket with MessagePack encoding. Fire-and-forget writes. All state changes arrive through one pathway — the WebSocket event stream.

## API

```typescript
import { Dust } from '@dust-sync/sdk'

const dust = new Dust({
  url: 'wss://app.dust.dev/ws/sync',
  token: process.env.DUST_API_KEY,
})

// CRUD
await dust.put('org/store', 'users.alice.name', 'Alice')
const value = await dust.get('org/store', 'users.alice.name')
await dust.merge('org/store', 'settings', { theme: 'dark' })
await dust.delete('org/store', 'users.bob')

// Types
await dust.increment('org/store', 'stats.views', 1)
await dust.add('org/store', 'post.tags', 'typescript')
await dust.remove('org/store', 'post.tags', 'draft')

// Subscribe
dust.on('org/store', 'users.**', (event) => {
  console.log(event.op, event.path, event.value)
})

// Query
const entries = await dust.enum('org/store', 'users.*')

// Status and cleanup
dust.status('org/store') // { connected: true, seq: 42 }
dust.close()
```

Writes return `Promise<{ storeSeq: number }>`. The promise resolves when the server accepts the write. Local state updates when the event arrives back through the WebSocket.

No optimistic writes. Simpler, correct, matches the webhook contract.

## Module Structure

```
sdk/typescript/
├── package.json          # @dust-sync/sdk
├── tsconfig.json
├── tsup.config.ts        # ESM + CJS output
├── src/
│   ├── index.ts          # re-exports Dust class + types
│   ├── dust.ts           # main client class
│   ├── connection.ts     # WebSocket + Phoenix Channel v2
│   ├── cache.ts          # cache interface + memory impl
│   ├── codec.ts          # JSON/MessagePack encode/decode
│   ├── glob.ts           # pattern matching for on() + enum()
│   └── types.ts          # Event, Entry, Status, DustOptions
└── test/
    └── *.test.ts
```

**Dependencies:** `ws` (Node WebSocket), `msgpackr` (MessagePack). Zero other deps.

## Connection Lifecycle

1. `new Dust(opts)` stores config. No connection yet.
2. First operation triggers lazy connect. WebSocket opens with query params: `token`, `device_id`, `capver=1`, `vsn=2.0.0`.
3. First access to a store sends `phx_join` on `store:{name}` with `{last_store_seq: cache.lastSeq(store)}`.
4. Server replies with `{store_seq, capver, capver_min}`, sends catch-up events, then `catch_up_complete`.
5. Queued operations flush.

**Event handling — single truth pathway:**

```
Server event → decode → update cache → advance lastSeq → fire callbacks
```

All state changes flow through this path. Writes, other devices' changes, catch-up — everything.

**Reconnection:** Exponential backoff (1s, 2s, 4s, 8s, cap 30s). On reconnect, rejoin all stores with `last_store_seq` from cache.

**Heartbeat:** Every 30 seconds.

## Cache

In-memory by default. Interface:

```typescript
interface Cache {
  get(store: string, path: string): Entry | null
  set(store: string, path: string, entry: Entry): void
  delete(store: string, path: string): void
  entries(store: string, pattern: string): Entry[]
  lastSeq(store: string): number
  setLastSeq(store: string, seq: number): void
}
```

No persistent adapter in v1. Memory suits AI agents and serverless. Persistent cache (`@dust-sync/cache-sqlite`) can follow.

## MessagePack — Server Changes

One new file: `DustWeb.MsgpackSerializer`. Copy of `Phoenix.Socket.V2.JSONSerializer` with Jason swapped for Msgpax and `:text` swapped for `:binary`.

Endpoint config adds it alongside the JSON serializer:

```elixir
serializer: [
  {DustWeb.MsgpackSerializer, "~> 2.0.0"},
  {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
]
```

Add `msgpax` to `server/mix.exs` deps. No channel or Writer changes — the serializer handles encoding at the transport layer.

No capver bump. MessagePack is a transport encoding choice; both formats carry the same data.

## Phoenix Channel v2 Wire Protocol

The TS SDK speaks Phoenix Channel v2 directly. Each message is a 5-element array:

```
[join_ref, ref, topic, event, payload]
```

Encoded as JSON text frames or MessagePack binary frames depending on the negotiated serializer.

Events: `phx_join`, `phx_reply`, `phx_leave`, `phx_close`, `phx_error`, `heartbeat`, `event`, `snapshot`, `catch_up_complete`.

## Deferred

- Optimistic writes with rollback (v2, if users ask)
- Persistent cache adapters (SQLite, IndexedDB)
- File upload/download (use REST API directly for now)
- Browser bundle optimization
