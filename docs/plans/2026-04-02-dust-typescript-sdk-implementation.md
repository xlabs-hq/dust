# TypeScript SDK + MessagePack Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a TypeScript SDK (`@dust-sync/sdk`) with MessagePack wire format support on the server.

**Architecture:** The TS SDK speaks Phoenix Channel v2 over WebSocket with MessagePack encoding. Fire-and-forget writes, single truth pathway for state changes. In-memory cache. The server adds a MsgpackSerializer alongside the existing JSON serializer.

**Tech Stack:** TypeScript, tsup, ws, msgpackr, vitest (server: Elixir, Msgpax)

---

### Task 1: Server — MessagePack Serializer

**Files:**
- Create: `server/lib/dust_web/msgpack_serializer.ex`
- Modify: `server/lib/dust_web/endpoint.ex:14-18`
- Modify: `server/mix.exs` (add msgpax dep)
- Create: `server/test/dust_web/msgpack_serializer_test.exs`

**What to build:**

Copy `Phoenix.Socket.V2.JSONSerializer` (160 lines, read from `server/deps/phoenix/lib/phoenix/socket/serializers/v2_json_serializer.ex`) into `DustWeb.MsgpackSerializer`. Make three changes:

1. In `fastlane!/1` for map payloads (line 28-31): replace `Phoenix.json_library().encode_to_iodata!(data)` with `Msgpax.pack!(data, iodata: false)` and `:text` with `:binary`
2. In `encode!/1` for Reply and Message map payloads (lines 63-72, 95-98): same swap
3. In `decode!/2` (lines 104-122): route `:binary` opcode through a new `decode_msgpack/1` that calls `Msgpax.unpack!/1` and builds the Message struct. Keep the binary-header clauses unchanged.

Important detail: the JSON serializer sends text frames with JSON arrays. The MsgPack serializer sends binary frames with MessagePack-encoded arrays. The binary-header protocol (for `{:binary, data}` payloads) stays the same in both — it's a custom compact format independent of the serializer.

For `decode!/2`, the MsgPack serializer receives `:binary` opcode for BOTH msgpack-encoded messages AND the custom binary-header format. Distinguish them: if the first byte is `@push` (0), `@reply` (1), or `@broadcast` (2), it's the binary-header format. Otherwise it's a MsgPack-encoded message.

Add `{:msgpax, "~> 2.4"}` to `server/mix.exs` deps.

Update endpoint config to list both serializers:

```elixir
socket "/ws/sync", DustWeb.StoreSocket,
  websocket: [
    connect_info: [:peer_data],
    serializer: [
      {DustWeb.MsgpackSerializer, "~> 2.0.0"},
      {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
    ]
  ]
```

**Tests:** Test encode/decode roundtrip for Reply, Message, and Broadcast with map payloads. Verify binary-header passthrough still works.

**Verify:** Run `cd server && mix test` — all existing JSON tests must still pass.

**Commit:** `feat: add MessagePack WebSocket serializer`

---

### Task 2: TS SDK — Project Scaffolding

**Files:**
- Create: `sdk/typescript/package.json`
- Create: `sdk/typescript/tsconfig.json`
- Create: `sdk/typescript/tsup.config.ts`
- Create: `sdk/typescript/src/index.ts`
- Create: `sdk/typescript/src/types.ts`
- Create: `sdk/typescript/vitest.config.ts`

**package.json:**

```json
{
  "name": "@dust-sync/sdk",
  "version": "0.1.0",
  "description": "TypeScript client for Dust reactive state sync",
  "main": "dist/index.js",
  "module": "dist/index.mjs",
  "types": "dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.mjs",
      "require": "./dist/index.js",
      "types": "./dist/index.d.ts"
    }
  },
  "scripts": {
    "build": "tsup",
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "ws": "^8.0.0",
    "msgpackr": "^1.10.0"
  },
  "devDependencies": {
    "typescript": "^5.4.0",
    "tsup": "^8.0.0",
    "vitest": "^1.6.0",
    "@types/ws": "^8.5.0"
  }
}
```

**tsup.config.ts:**

```typescript
import { defineConfig } from 'tsup'

export default defineConfig({
  entry: ['src/index.ts'],
  format: ['cjs', 'esm'],
  dts: true,
  clean: true,
})
```

**src/types.ts** — shared type definitions:

```typescript
export interface DustOptions {
  url: string
  token: string
  deviceId?: string
  format?: 'msgpack' | 'json'
}

export interface Entry {
  path: string
  value: unknown
  type: string
  seq: number
}

export interface Event {
  storeSeq: number
  op: string
  path: string
  value: unknown
  deviceId: string
  clientOpId: string
}

export interface Status {
  connected: boolean
  seq: number
}

export type EventCallback = (event: Event) => void
```

**src/index.ts** — re-exports:

```typescript
export { Dust } from './dust'
export type { DustOptions, Entry, Event, Status, EventCallback } from './types'
```

**Install deps, verify build:**

```bash
cd sdk/typescript && npm install && npm run build
```

**Commit:** `feat: scaffold TypeScript SDK project`

---

### Task 3: TS SDK — Codec (JSON + MessagePack)

**Files:**
- Create: `sdk/typescript/src/codec.ts`
- Create: `sdk/typescript/test/codec.test.ts`

**What to build:**

Encode/decode functions for both formats. The Phoenix v2 wire format is a 5-element array `[join_ref, ref, topic, event, payload]`.

```typescript
import { pack, unpack } from 'msgpackr'

export interface WireMessage {
  joinRef: string | null
  ref: string | null
  topic: string
  event: string
  payload: unknown
}

export function encode(msg: WireMessage, format: 'msgpack' | 'json'): Buffer | string {
  const arr = [msg.joinRef, msg.ref, msg.topic, msg.event, msg.payload]
  if (format === 'msgpack') return Buffer.from(pack(arr))
  return JSON.stringify(arr)
}

export function decode(data: Buffer | string, format: 'msgpack' | 'json'): WireMessage {
  const arr = format === 'msgpack' ? unpack(Buffer.from(data as Buffer)) : JSON.parse(data as string)
  return {
    joinRef: arr[0],
    ref: arr[1],
    topic: arr[2],
    event: arr[3],
    payload: arr[4],
  }
}
```

**Tests:** Roundtrip encode/decode for both formats. Verify msgpack produces smaller output than JSON.

**Commit:** `feat: add codec with JSON and MessagePack support`

---

### Task 4: TS SDK — Glob Pattern Matching

**Files:**
- Create: `sdk/typescript/src/glob.ts`
- Create: `sdk/typescript/test/glob.test.ts`

**What to build:**

Pattern matching for subscriptions and `enum()`. Dust paths use dots as separators. `*` matches one segment, `**` matches one or more.

```typescript
export function match(pattern: string, path: string): boolean {
  // Convert dust glob to regex
  // "users.*" → matches "users.alice" but not "users.alice.name"
  // "users.**" → matches "users.alice" and "users.alice.name"
}
```

**Tests:** Cover `*`, `**`, exact match, no match, nested patterns.

**Commit:** `feat: add glob pattern matching for subscriptions`

---

### Task 5: TS SDK — Cache (Memory Implementation)

**Files:**
- Create: `sdk/typescript/src/cache.ts`
- Create: `sdk/typescript/test/cache.test.ts`

**What to build:**

```typescript
export interface Cache {
  get(store: string, path: string): Entry | null
  set(store: string, path: string, entry: Entry): void
  delete(store: string, path: string): void
  entries(store: string, pattern: string): Entry[]
  lastSeq(store: string): number
  setLastSeq(store: string, seq: number): void
}

export class MemoryCache implements Cache {
  // Map<string, Map<string, Entry>> keyed by store, then path
  // Separate Map<string, number> for lastSeq per store
}
```

`entries(store, pattern)` uses the glob module to filter.

**Tests:** CRUD, pattern queries, lastSeq tracking.

**Commit:** `feat: add in-memory cache for TypeScript SDK`

---

### Task 6: TS SDK — Connection (Phoenix Channel v2)

**Files:**
- Create: `sdk/typescript/src/connection.ts`
- Create: `sdk/typescript/test/connection.test.ts`

**What to build:**

The core WebSocket client implementing Phoenix Channel v2. This is the biggest module.

```typescript
export class Connection {
  private ws: WebSocket | null = null
  private refCounter = 0
  private pendingReplies = new Map<string, { resolve, reject, timeout }>()
  private channels = new Map<string, ChannelState>()
  private eventHandlers = new Map<string, Set<EventCallback>>()
  private heartbeatInterval: NodeJS.Timer | null = null

  constructor(private opts: DustOptions, private codec: Codec) {}

  async connect(): Promise<void>
  async join(store: string, lastSeq: number): Promise<JoinReply>
  async push(topic: string, event: string, payload: object): Promise<unknown>
  onEvent(topic: string, handler: EventCallback): () => void
  close(): void

  // Internal
  private buildUrl(): string  // ws URL + query params (token, device_id, capver, vsn)
  private send(msg: WireMessage): void
  private handleMessage(data: Buffer | string): void
  private handleReply(msg: WireMessage): void
  private handleBroadcast(msg: WireMessage): void
  private startHeartbeat(): void
  private reconnect(): void
  private nextRef(): string
}
```

Key behaviors:
- `connect()`: opens WebSocket, starts heartbeat, resolves on open
- `join()`: sends `phx_join`, waits for reply, returns `{storeSeq, capver, capverMin}`
- `push()`: sends message with ref, waits for `phx_reply` matching that ref (with timeout)
- `onEvent()`: registers handler for broadcast events on a topic. Returns unsubscribe function.
- Heartbeat: sends `[null, ref, "phoenix", "heartbeat", {}]` every 30s
- Reconnect: exponential backoff (1s, 2s, 4s, 8s, cap 30s), rejoins all channels
- Message routing: `phx_reply` → resolve pending, `event`/`snapshot`/`catch_up_complete` → fire handlers

Use `ws` package on Node.js. Check for native `globalThis.WebSocket` first (browsers, Deno, Bun).

**Tests:** Unit tests for URL building, ref counting, message encoding. Integration tests would need a server — defer those to Task 8.

**Commit:** `feat: add Phoenix Channel v2 WebSocket client`

---

### Task 7: TS SDK — Main Client Class

**Files:**
- Create: `sdk/typescript/src/dust.ts`
- Create: `sdk/typescript/test/dust.test.ts`

**What to build:**

The `Dust` class orchestrates Connection, Cache, and subscriptions.

```typescript
export class Dust {
  private connection: Connection
  private cache: MemoryCache
  private subscriptions: Map<string, Set<{ pattern: string, callback: EventCallback }>>
  private joinedStores: Set<string>

  constructor(opts: DustOptions)

  // Public API
  async get(store: string, path: string): Promise<unknown>
  async put(store: string, path: string, value: unknown): Promise<{ storeSeq: number }>
  async merge(store: string, path: string, value: Record<string, unknown>): Promise<{ storeSeq: number }>
  async delete(store: string, path: string): Promise<{ storeSeq: number }>
  async increment(store: string, path: string, delta?: number): Promise<{ storeSeq: number }>
  async add(store: string, path: string, member: unknown): Promise<{ storeSeq: number }>
  async remove(store: string, path: string, member: unknown): Promise<{ storeSeq: number }>
  on(store: string, pattern: string, callback: EventCallback): () => void
  async enum(store: string, pattern: string): Promise<Entry[]>
  status(store: string): Status
  close(): void

  // Internal
  private async ensureJoined(store: string): Promise<void>
  private handleEvent(store: string, event: Event): void
  private handleSnapshot(store: string, data: object): void
  private handleCatchUpComplete(store: string, throughSeq: number): void
}
```

**`get()`**: Read from cache. If not joined, join first (triggers catch-up). Return value at path.

**`put()`/`merge()`/etc**: Ensure joined, push `"write"` message, return `{storeSeq}` from reply. State updates when event arrives.

**`on()`**: Register callback. Ensure joined. Return unsubscribe function.

**`handleEvent()`**: Update cache, advance lastSeq, fire matching callbacks. This is the single truth pathway.

**Tests:** Unit tests for subscription matching, cache integration, event handling. Can test without a real server by mocking the Connection.

**Commit:** `feat: add Dust client class with full API surface`

---

### Task 8: Integration Test — TS SDK against Dust Server

**Files:**
- Create: `sdk/typescript/test/integration.test.ts`

**What to build:**

An integration test that connects the TS SDK to the real Dust server. Requires the server to be running.

Tests:
- Connect and join a store
- Put a value, receive the event back, verify cache updated
- Get the value from cache
- Subscribe, write from another connection, verify callback fires
- Enum with pattern matching
- Increment, verify materialized value in event
- Reconnect and catch-up

**Setup:** Use `beforeAll` to create a test store via the REST API. Use `afterAll` to clean up.

Mark this test file as requiring a running server (separate vitest config or `.skip` by default).

**Commit:** `feat: add integration tests for TypeScript SDK`

---

### Task 9: Build, Typecheck, and Package Verification

**Steps:**

1. `cd sdk/typescript && npm run build` — verify clean build
2. `cd sdk/typescript && npm run typecheck` — verify no TS errors
3. `cd sdk/typescript && npm test` — run unit tests
4. `cd server && mix test` — verify server still green
5. `cd server && mix compile --warnings-as-errors` — zero warnings

**Commit:** `style: format and clean up TypeScript SDK`

---

### Implementation Notes

**Phoenix Channel v2 specifics for the TS client:**

The client must send `vsn=2.0.0` in the query params to use the v2 protocol. For MessagePack, the client sends binary WebSocket frames. For JSON, text frames.

The `phx_reply` payload shape is:
```json
[join_ref, ref, topic, "phx_reply", {"status": "ok", "response": {...}}]
```

The server uses `"ok"` or `"error"` as status strings.

**MessagePack gotchas:**
- `msgpackr` handles Buffer ↔ object conversion natively
- Phoenix's MsgPack serializer will send binary frames — the client must handle both binary and text frames (for JSON fallback)
- Map keys come back as strings (not atoms) from both formats

**Device ID generation:**
```typescript
const deviceId = 'dev_' + crypto.randomUUID().replace(/-/g, '').slice(0, 16)
```
