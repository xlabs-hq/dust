# Dust Phase 1: Vertical Slice Design

Server + Elixir SDK + protocol spec. Core operations only (set, get, delete, merge). Proves the sync engine works end-to-end.

Reference: [Dust v4 design](2026-03-26-dust-design-v4.md) is the product spec. This document covers architecture and implementation decisions for the first phase.

## Project Structure

```
dust/
  docs/plans/
  server/            # Phoenix app (Dust)
  sdk/elixir/        # Library (dust hex package)
  protocol/
    spec/            # AsyncAPI + sync semantics (language-agnostic)
    elixir/          # Elixir implementation (dust_protocol)
  cli/               # Crystal native binary (phase 2)
```

**Server** is a Phoenix app named `Dust`. Web module is `DustWeb`. Follows the [Phoenix Architecture Guide](../../../agents/PHOENIX_ARCHITECTURE_GUIDE.md): dual endpoints, WorkOS auth, UUIDv7, Oban, let_me, Inertia/React dashboard, LiveView admin.

**Protocol** has two layers. `spec/` defines the wire format as an AsyncAPI 3.0 document (message shapes, channels, operations, MessagePack and JSON serialization) plus a prose sync-semantics doc (conflict resolution, catch-up, ordering, reconciliation). `elixir/` implements the spec as a Mix library shared by server and SDK via path dependency.

**SDK** is a library other Elixir apps add to their supervision tree. Connects to the server over WebSocket, caches locally via a pluggable adapter, handles optimistic writes and reconciliation, dispatches glob-pattern callbacks.

**CLI** ships in phase 2 as a Crystal native binary. It implements the wire protocol from `spec/` directly — the first non-Elixir client, validating that the spec is sufficient for any language.

## Server Data Model

All tables use UUIDv7 primary keys with `read_after_writes: true`.

### Accounts

- **users** — `email`, `workos_id`, `first_name`, `last_name`.
- **organizations** — `name`, `slug`, `workos_organization_id`. The slug is the namespace prefix in store names (`james`, `acme`).
- **organization_memberships** — `user_id`, `organization_id`, `role` (owner/admin/member/guest).

### Stores

- **stores** — `organization_id`, `name` (the segment after the slash), `status` (active/archived). Unique on `(organization_id, name)`. Full store name: `{org.slug}/{store.name}`.
- **store_tokens** — `store_id`, `token_hash`, `name`, `permissions` (read/write), `created_by_id`, `expires_at`. Scoped API keys.
- **devices** — `user_id`, `name`, `device_id` (public identifier on the wire), `last_seen_at`.

### Sync Engine

- **store_ops** — `store_id`, `store_seq` (bigint, monotonic), `op` (set/delete/merge), `path`, `value` (jsonb), `type`, `device_id`, `client_op_id`, `inserted_at`. Append-only op log. Indexed on `(store_id, store_seq)`.
- **store_entries** — `store_id`, `path`, `value` (jsonb), `type`, `seq` (the `store_seq` that last touched this entry). Materialized current state. Primary key `(store_id, path)`.
- **store_snapshots** — `store_id`, `snapshot_seq`, `snapshot_data` (jsonb). For catch-up when a client falls behind the compaction point.

The store's GenServer writes to both `store_ops` and `store_entries` in a single transaction.

## WebSocket Sync Engine

### Connection Flow

1. Client opens WebSocket to `/ws/sync` with subprotocol `dust.msgpack` or `dust.json`.
2. Client sends hello: `{capver: 1, device_id: "dev_abc", token: "dust_tok_..."}`.
3. Server authenticates the token, resolves store permissions, responds with hello: `{capver_min: 1, capver_max: 1, your_capver: 1, stores: [...]}`.
4. Client joins a store: `{join, store: "james/blog", last_store_seq: 41}`.
5. Server sends catch-up events (all ops after seq 41), then streams live updates.

### Phoenix Channel Mapping

One Channel module: `DustWeb.StoreChannel`. Topic per store: `"store:james/blog"`.

- `join/3` — authenticates token against store, checks permissions, triggers catch-up.
- `handle_in("write", ...)` — routes the write to the store's GenServer.
- Outbound broadcasts carry server-confirmed events to all connected clients.

Subprotocol negotiation selects the serializer: MessagePack for production, JSON for development and debugging.

### Store GenServer (`Dust.Stores.Writer`)

One process per active store, registered via `Registry`. Started on first connection, shuts down after an idle timeout.

Write path:
1. Receive write request (op, path, value, device_id, client_op_id).
2. Inside a DB transaction: read current `store_seq`, increment it, insert into `store_ops`, upsert `store_entries` with conflict resolution applied.
3. After commit, broadcast the canonical event to `Phoenix.PubSub` on `"store:james/blog"`.
4. The Channel picks up the broadcast and pushes to all connected clients.
5. Origin client matches `client_op_id` to reconcile its optimistic write.

### Conflict Resolution (Phase 1)

Phase 1 implements the LWW and structural merge rules for scalar types and maps:

- **Unrelated paths** — both writes survive.
- **Same path** — later `store_seq` wins.
- **Ancestor vs descendant** — `set` or `delete` on an ancestor replaces the subtree. A later descendant write recreates under that path.
- **`merge` semantics** — touches only named child keys; unmentioned siblings survive.
- **`merge` vs `set` on the same path** — later committed op wins.

Counter, set, and file merge rules ship in phase 2.

### Catch-Up Sync

On join, the Channel queries `store_ops WHERE store_seq > last_store_seq ORDER BY store_seq` and streams events in order. If the client is behind the compaction point, send the snapshot first, then the op tail after `snapshot_seq`.

## Elixir SDK

### Supervision Tree

```elixir
{Dust, stores: ["james/blog"], cache: {Dust.Cache.Ecto, repo: MyApp.Repo}}
```

Starts:
- **`Dust.Connection`** — WebSocket client to the server. Handles connect, reconnect with backoff, hello handshake, catch-up. Uses `Mint.WebSocket`.
- **`Dust.SyncEngine`** — GenServer per store. Receives events from the connection, writes to the cache adapter, manages the optimistic write queue, reconciles server echoes, dispatches callbacks.
- **`Dust.CallbackRegistry`** — ETS-backed registry of glob-pattern subscriptions.

### Cache Adapter Behaviour

```elixir
@callback read(store, path) :: {:ok, value} | :miss
@callback read_all(store, pattern) :: [{path, value}]
@callback write(store, path, value, type, seq) :: :ok
@callback write_batch(store, entries) :: :ok
@callback delete(store, path) :: :ok
@callback last_seq(store) :: integer()
```

Phase 1 ships one adapter: `Dust.Cache.Ecto` (Postgres/MySQL/SQLite via Ecto). Ships with a migration generator (`mix dust.gen.migration`).

### Public API

```elixir
Dust.get(store, path)
Dust.put(store, path, value)
Dust.delete(store, path)
Dust.merge(store, path, map)
Dust.on(store, pattern, callback)
Dust.enum(store, pattern)
Dust.status(store)
```

`status/1` returns per-store sync state: connection status (`:connected`, `:reconnecting`, `:disconnected`), `last_store_seq`, pending outbound ops count, last sync timestamp.

### Optimistic Writes

1. `Dust.put/3` writes to the local cache immediately and returns.
2. Matching local callbacks fire with `committed: false`, `source: :local`.
3. The sync engine sends the op to the server in the background.
4. On server echo: if accepted as-is, mark committed, no second callback. If corrected, apply canonical state, fire callback with `committed: true`, `source: :server`, `correction_for: client_op_id`. If rejected, roll back local state, fire error callback.

## Protocol Spec

### AsyncAPI Document (`protocol/spec/asyncapi.yaml`)

Defines:
- **Channels**: `store:{namespace}/{name}` — the sync topic for a store.
- **Messages**: `Hello`, `HelloResponse`, `Join`, `Write`, `Event`, `CatchUpBatch`, `Error`.
- **Operations**: `sendHello`, `receiveHelloResponse`, `sendJoin`, `sendWrite`, `receiveEvent`, etc.
- **Schemas**: MessagePack and JSON representations for each message type, using AsyncAPI's multi-format schema support.
- **Server bindings**: WebSocket with `dust.msgpack` and `dust.json` subprotocols.

### Sync Semantics Document (`protocol/spec/sync-semantics.md`)

Covers what AsyncAPI cannot express:
- Server-authoritative ordering: one `store_seq` per store, monotonically increasing.
- Conflict resolution rules (path scope, LWW, structural merge).
- Optimistic write lifecycle (local apply → server echo → reconcile).
- Catch-up sync protocol (send `last_store_seq`, receive tail or snapshot + tail).
- Backpressure: bounded subscription queue, `resync_required` on overflow.
- Capability versioning: single integer, negotiated on hello.
- Recovery pattern: `enum` on boot, `on` for live updates, repeat on restart.

## Smoke Tests

Integration tests against a real server with real Postgres. No mocks for the sync path.

1. **Connect & auth** — Valid token gets hello response. Invalid token gets rejection.
2. **Basic CRUD** — Put, get, merge, delete. Verify round-trip through server.
3. **Two-client sync** — Client A writes, client B receives the event. Bidirectional.
4. **Optimistic reconciliation** — Write returns immediately. Server echo matches on `client_op_id`. Local callback fires once (not twice) when accepted as-is.
5. **Conflict: same path** — Two clients write to the same path. Later `store_seq` wins. Both clients converge.
6. **Conflict: ancestor vs descendant** — `set("posts", ...)` after `set("posts.hello", ...)` removes the child. Later descendant recreates under ancestor.
7. **Conflict: merge vs set** — Concurrent merge and set on the same path. Later committed op wins.
8. **Catch-up sync** — Client A writes 10 ops. Client B joins with `last_store_seq: 0`, receives all 10 in order.
9. **Reconnect catch-up** — Client receives events, disconnects, reconnects with its `last_store_seq`, receives only missed events.
10. **Glob subscriptions** — Subscribe to `posts.*`. Fires for `posts.hello`, not for `posts.hello.title`, not for `config.x`.
11. **Enum** — Populate store, `enum("posts.*")` returns the correct subset.
12. **Backpressure** — Flood a subscription past the queue limit, verify `resync_required`.

## Phases

### Phase 1 (this plan)
Server + Elixir SDK + protocol spec. Core ops: set, get, delete, merge. WebSocket sync with MessagePack/JSON. Ecto cache adapter. Smoke test suite.

### Phase 2
Full type system on server (counters, sets, files, decimals, datetimes). Audit log and rollback. Crystal CLI (first non-Elixir client). MCP endpoint on server.

### Phase 3
Ruby, Python, TypeScript SDKs. Each implements the wire protocol from `protocol/spec/`.
