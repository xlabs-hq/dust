# Dust Sync Semantics

Companion to `asyncapi.yaml`. Covers behavioral semantics that the schema cannot express.

## Server-Authoritative Ordering

Each store has a single monotonically increasing `store_seq`. The server assigns it.
Clients never generate `store_seq` — they generate `client_op_id` for reconciliation.

One write at a time per store. The server processes writes sequentially.

## Conflict Resolution

### Path Scope Rules

- **Unrelated paths** (neither is ancestor of the other): both writes survive.
- **Same path**: later `store_seq` replaces the earlier value.
- **Ancestor vs descendant**: `set` or `delete` on ancestor replaces the subtree.
  A later descendant write recreates under that path.
- **`merge(path, map)`**: updates only named child keys. Unmentioned siblings survive.
- **`merge` vs `set` on the same path**: later committed op wins.

### Path Syntax

Paths are dot-separated segments: `posts.hello.title`.

- Segments are non-empty strings.
- Path `a` is ancestor of `a.b` and `a.b.c`.
- Path `a` is not ancestor of `ab` or `a` itself.

## Optimistic Write Lifecycle

1. Client writes locally, generates `client_op_id`, fires local callbacks with `committed: false`.
2. Client sends write to server.
3. Server assigns `store_seq`, persists, broadcasts event to all clients.
4. Origin client matches `client_op_id`:
   - Accepted as-is → mark committed, no second callback.
   - Corrected → apply canonical state, fire callback with `correction_for`.
   - Rejected → roll back local state, fire error callback.

## Catch-Up Sync

1. Client sends `last_store_seq` on join.
2. Server responds with all events where `store_seq > last_store_seq`, in order.
3. If client is behind compaction point, server sends snapshot at `snapshot_seq`,
   then the op tail after `snapshot_seq`.

## Callback Semantics

Subscriptions are live, not durable. Not replayed across restarts.

Recovery pattern:
1. `enum` on boot to build current state.
2. `on` to receive live changes.
3. Repeat on restart.

### Glob Pattern Matching

- `*` matches exactly one path segment.
- `**` matches one or more path segments.
- Exact paths match exactly.

### Backpressure

Each subscription has a bounded queue (default 1,000 events).
If exceeded, subscription is dropped and `resync_required` is raised.
Store sync continues — one slow subscriber does not stall the store.

## Capability Versioning

Single integer, sent in hello. MVP ships with `capver = 1`.
Server responds with `capver_min` and `capver_max`.
If client capver is outside the range, connection is rejected.

## Wire Encoding

Two subprotocols:
- `dust.msgpack` — MessagePack encoding. Production default.
- `dust.json` — JSON encoding. Development and debugging.

Both encode the same message shapes defined in `asyncapi.yaml`.
