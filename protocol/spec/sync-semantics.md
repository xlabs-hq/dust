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

## Compare-and-swap writes

Clients can make optimistic-concurrency writes by attaching an `if_match`
field to a write payload. This turns a normal last-writer-wins `set` into a
compare-and-swap against the target entry's current seq (revision).

- `if_match` is an **optional integer** on `set` write payloads. Its value is
  the seq the client believes the target entry currently has.
- If present, the server compares the target entry's current `seq` to
  `if_match` **inside the same SQLite transaction** that performs the write.
  There is no TOCTOU race: the check and the write are atomic.
- **Match** → the write proceeds normally, the entry's seq is bumped, and the
  reply is `{store_seq: N}` as usual.
- **Mismatch** (the entry exists but its seq differs) → the server replies
  with `{error: {reason: "conflict", current_revision: N}}` and the write is
  not applied. The entry is unchanged.
- **Missing entry** (the path does not exist) → also treated as a conflict:
  `{error: {reason: "conflict", current_revision: null}}`. The precondition
  "this entry exists with seq N" is false.

### Scope

Phase 5 CAS is deliberately narrow:

- Only `set` ops support `if_match`. Sending `if_match` with any other op
  (`delete`, `merge`, `increment`, `add`, `remove`, `put_file`, ...) returns
  `{error: {reason: "if_match_unsupported_op"}}`.
- Only **leaf** (non-dict) values are supported. A `set` with a dict value
  flattens to multiple leaves and cannot be CAS'd atomically without a
  subtree index, so the server returns
  `{error: {reason: "if_match_multi_leaf"}}`.
- `if_match` is a positive integer. There is no `0` sentinel for "must not
  exist" and no wildcard.

### Capver gate

`if_match` requires **capver >= 2**. A capver=1 client that sends `if_match`
gets `{error: {reason: "capver_mismatch"}}`. This prevents silent downgrade:
old clients never receive conflict errors because they can't send `if_match`
in the first place.

## Capability Versioning

Single integer, sent in hello. Current version is `capver = 2`.
Server responds with `capver_min` and `capver_max`.
If client capver is outside the range, connection is rejected.

Capver history:

- **1** — initial protocol. All base op types over JSON/msgpack.
- **2** — adds optional `if_match` on `set` writes (leaf values only) and the
  `conflict` / `capver_mismatch` / `if_match_unsupported_op` /
  `if_match_multi_leaf` reply reasons. The server still accepts capver=1
  joins for reads, but capver=1 clients cannot use CAS.

## Wire Encoding

Two subprotocols:
- `dust.msgpack` — MessagePack encoding. Production default.
- `dust.json` — JSON encoding. Development and debugging.

Both encode the same message shapes defined in `asyncapi.yaml`.
