# Dust KV-Native Features — Design

**Date:** 2026-04-13
**Status:** Approved for implementation

## Goal

Add a small set of KV-native traversal, bootstrap, and concurrency primitives that make Dust better for UI and index-style workloads without turning it into a database.

The accepted feature set is:

- paginated `enum`
- lexicographic `range`
- keys-only enumeration
- prefix listing
- `get_many`
- bootstrap watch via `include_current`
- CAS writes via `if_match`

## Design constraints

- Keep Dust's core identity: reactive global map, not a database.
- Extend existing verbs where possible instead of adding a second API family.
- Keep local reads cache-first. Most of this feature set should not require wire changes.
- Reserve protocol changes for true write-path changes only.
- Preserve current APIs by default. Richer behavior should be opt-in by arity or options.

### Cross-SDK guidelines (project-level)

These apply to every feature in this plan and beyond:

1. **Read features must be expressible as SQL against the cache schema.** Any read API added to any SDK must be answerable by a query against the local cache table. No read should require server-side computation, a server round-trip, or in-memory traversal the cache can't replicate. If a proposed read can't be expressed in SQL, either redesign it or reject it. This is what makes HTTP SDKs (Ruby/Python) work: their steady-state read path is local SQLite against a webhook-hydrated cache, identical in shape to the Elixir Ecto adapter.

2. **Cache schemas must stay as similar as possible across SDKs.** The Elixir Ecto adapter, the TypeScript SDK cache, and the future Ruby/Python SQLite caches should share column names, types, indexes, and `seq` semantics as closely as the host language allows. Divergence compounds quickly and makes cross-language debugging and feature porting painful. When adding a column or index, add it everywhere or explain why not.

### SDK architecture model

- **Elixir SDK** — WebSocket + local cache (Memory or Ecto/SQLite adapter).
- **TypeScript SDK** — WebSocket + MessagePack + local cache.
- **Ruby SDK** — HTTP writes + webhook hydration + local SQLite cache (same schema shape as Elixir Ecto adapter). Pre-fork workers share the SQLite file on disk; the webhook receiver writes, all workers read.
- **Python SDK** — Same shape as Ruby.

Implication: `on(pattern, callback)` in-process subscription is Elixir/TS only. In Ruby/Python, the customer's webhook route handler **is** the subscription — there is no in-process callback registry, because webhooks arrive at one pre-fork worker and can't be fanned to siblings without IPC. This is intentional and matches how Rails/Django devs already handle third-party webhooks (Stripe, etc.).

## Non-goals

- per-key TTL
- query language or secondary indexes
- durable replay subscriptions
- arbitrary delimiters beyond Dust path semantics
- multi-key transactions

## Public API

### Enumeration

Keep the current API unchanged:

```elixir
Dust.enum(store, pattern)
# => [{path, value}, ...]
```

Add a richer arity:

```elixir
Dust.enum(store, pattern, opts)
# => %Dust.Page{items: ..., next_cursor: ...}
```

`enum/3` options:

- `limit:` page size
- `after:` opaque cursor
- `order:` `:asc` or `:desc`
- `select:` `:entries | :keys | :prefixes`
- `delimiter:` `"."` only, required for `select: :prefixes`

Semantics:

- `select: :entries` returns `{path, value}` items.
- `select: :keys` returns `path` strings only.
- `select: :prefixes` returns unique immediate path prefixes, using Dust path segments rather than object-store folder semantics.
- `enum/2` remains the compatibility API for callers that want the full list with the existing return shape.

### Range

Add:

```elixir
Dust.range(store, from, to, opts \\ [])
# => %Dust.Page{items: ..., next_cursor: ...}
```

`range/4` options:

- `limit:`
- `after:`
- `order:`
- `select: :entries | :keys`

Semantics:

- lexicographic over full path strings
- `from` inclusive
- `to` exclusive
- intended for ULID-ordered namespaces and prefix-bounded scans

### Batch Read

Add:

```elixir
Dust.get_many(store, paths)
# => %{path => value, ...}
```

Semantics:

- keys missing from the cache are omitted from the result map
- preserves Dust's current `get` behavior of returning materialized values, not envelopes

### Bootstrap Watch

The existing public API already supports `on/4`, so the bootstrap form should be expressed there first:

```elixir
Dust.on(store, pattern, callback,
  include_current: true,
  limit: 20,
  order: :desc
)
```

Optional helper:

```elixir
Dust.watch(store, pattern, callback, opts \\ [])
```

Semantics:

- registration and bootstrap must happen atomically inside the `SyncEngine`
- matching current entries are emitted first
- live events continue through the same callback stream after bootstrap
- this is a convenience over the documented `enum` then `on` recovery pattern, not a durable replay system

### CAS Writes

Keep the current API unchanged:

```elixir
Dust.put(store, path, value)
```

Add an opt-in arity:

```elixir
Dust.put(store, path, value, if_match: revision)
```

To support this cleanly, add a metadata-bearing read:

```elixir
Dust.entry(store, path)
# => {:ok, %Dust.Entry{path: path, value: value, type: type, revision: revision}}
```

Initial CAS scope:

- `put/4` only
- **leaf paths only** — `if_match` on a subtree path returns `{:error, :unsupported}`
- stale revision returns `{:error, :conflict}`

Revision semantics:

- leaf path: the stored entry `seq`
- subtree path: `Dust.entry/2` still returns a revision (max descendant `seq`, computed on read as today) so callers can use it as an ETag or cache key, but it is not accepted by `put/4` in this phase

Subtree CAS is deferred. Accepting `if_match` on a subtree would require a prefix→max-seq index on the write path (today the max-descendant-seq walk only exists on reads in `server/lib/dust/sync.ex`). No current use case justifies that index; revisit if one appears.

## Compatibility strategy

### No wire changes for local-read features

These features can ship without protocol changes:

- `enum/3`
- `range/4`
- `get_many/2`
- `select: :keys`
- `select: :prefixes`
- `include_current` bootstrap behavior

They operate against the local cache or the local `SyncEngine` state.

### CAS requires protocol and server changes

CAS is the only accepted feature that changes the write path.

It requires:

- adding `if_match` to write payloads
- validating the current revision on the server before commit
- returning an explicit conflict reason
- capability-gating the feature

Capver plan:

- keep current read features on existing capver (`capver = 1`)
- ship CAS behind `capver = 2`

## Implementation phases

### Phase 1 — Elixir SDK enumeration upgrade

Goal: ship paginated enum, keys-only enum, and prefix listing through the existing cache adapters.

Files:

- `sdk/elixir/lib/dust.ex`
- `sdk/elixir/lib/dust/sync_engine.ex`
- `sdk/elixir/lib/dust/cache.ex`
- `sdk/elixir/lib/dust/cache/memory.ex`
- `sdk/elixir/lib/dust/cache/ecto.ex`

Work:

- add `enum/3`
- introduce `%Dust.Page{}`
- extend cache browse support for:
  - descending order
  - `select: :keys`
  - `select: :prefixes`
  - cursor naming alignment (`after` at API, adapter can still use `cursor` internally)
- keep `enum/2` behavior unchanged

Notes:

- `select: :prefixes` should use Dust path segments, not arbitrary string splitting
- `delimiter:` should be limited to `"."` for now

### Phase 2 — Range and batch reads

Goal: add explicit KV traversal and N-read batching.

Files:

- `sdk/elixir/lib/dust.ex`
- `sdk/elixir/lib/dust/sync_engine.ex`
- `sdk/elixir/lib/dust/cache.ex`
- `sdk/elixir/lib/dust/cache/memory.ex`
- `sdk/elixir/lib/dust/cache/ecto.ex`

Work:

- add `range/4`
- add `get_many/2`
- implement lexicographic range support in both cache adapters
- ensure all APIs remain local/cache-first

Notes:

- `range` is the preferred primitive for ULID-keyed namespaces
- `get_many` should avoid repeated adapter round-trips where possible

### Phase 3 — Bootstrap watch

Goal: collapse mount-time enumeration plus live subscription into one registration path.

Files:

- `sdk/elixir/lib/dust.ex`
- `sdk/elixir/lib/dust/sync_engine.ex`
- `sdk/elixir/lib/dust/callback_registry.ex`
- `sdk/elixir/lib/dust/callback_worker.ex`

Work:

- honor `include_current` in `on/4`
- execute registration and initial emission in one `GenServer.call`
- support `limit` and `order` during bootstrap
- optionally add `watch/4` as a public alias for readability

Important behavior:

- no race window between bootstrap and live events
- preserve current backpressure behavior
- current entries should be emitted as committed server state

### Phase 4 — TypeScript and CLI parity

Goal: keep non-Elixir clients aligned with the new read surface.

Files:

- `sdk/typescript/src/dust.ts`
- `sdk/typescript/src/cache.ts`
- `sdk/typescript/src/types.ts`
- `cli/src/dust/commands/data.cr`
- `cli/src/dust/commands/watch.cr`
- `cli/src/dust/cache/sqlite.cr`

Work:

- add paginated enum options
- add range and get-many
- add keys-only and prefixes projections
- add bootstrap watch semantics

Notes:

- TypeScript should mirror the Elixir shapes closely
- CLI should expose the richer read surface without inventing separate semantics

### Phase 5 — CAS reads and writes

Goal: add optimistic concurrency without changing Dust's core model.

Files:

- `sdk/elixir/lib/dust.ex`
- `sdk/elixir/lib/dust/sync_engine.ex`
- `sdk/elixir/lib/dust/connection.ex`
- `sdk/elixir/lib/dust/protocol.ex`
- `sdk/typescript/src/dust.ts`
- `sdk/typescript/src/connection.ts`
- `protocol/spec/asyncapi.yaml`
- `protocol/spec/sync-semantics.md`
- `server/lib/dust_web/channels/store_channel.ex`
- `server/lib/dust/sync.ex`
- `server/lib/dust/sync/writer.ex`

Work:

- add `Dust.entry/2`
- thread `if_match` through SDK write payloads
- validate current revision in the server write path before assigning `store_seq` (leaf paths only)
- reject `if_match` on subtree paths with `{:error, :unsupported}`
- return `{:error, :conflict}` on stale writes
- gate CAS behind `capver = 2`

Notes:

- CAS must validate against the authoritative server view, not the local cache. Callers cannot reliably pre-check `if_match` against the local cache; a stale write always round-trips and rolls back on conflict.
- conflict handling should reuse the existing write-rejection path where possible

## Testing plan

### Enumeration

- `enum/2` remains unchanged
- `enum/3` paginates with stable cursors
- ascending and descending order both work
- keys projection returns only paths
- prefixes projection returns unique immediate prefixes
- no duplicates across pages

### Range

- inclusive `from`
- exclusive `to`
- cursor continuation inside a bounded range
- descending scans behave correctly
- ULID-like keys page correctly

### Batch reads

- existing keys returned correctly
- missing keys omitted
- result shape stable across adapters

### Bootstrap watch

- current entries arrive first
- live writes after registration are not missed
- bootstrap ordering honors `limit` and `order`
- backpressure still drops slow subscribers correctly

### CAS

- matching revision on a leaf succeeds
- stale revision on a leaf conflicts
- `if_match` on a subtree path returns `{:error, :unsupported}`
- `Dust.entry/2` on a subtree still returns a usable revision
- optimistic local write rolls back cleanly on conflict
- mixed-capver clients continue to interoperate

## Delivery order

Recommended shipping order:

1. `enum/3` with paging and projections
2. `range/4`
3. `get_many/2`
4. bootstrap watch via `include_current`
5. TypeScript and CLI parity
6. CAS via `if_match`

This gives Dust the high-value UI and index primitives first, while deferring the only protocol-changing feature until the read surface is stable.
