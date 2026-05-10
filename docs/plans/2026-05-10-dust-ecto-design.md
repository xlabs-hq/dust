# dust_ecto — design

**Status:** revised, pre-implementation
**Date:** 2026-05-10 (revision 1)
**Authors:** James Tippett (with Claude)
**Related:** `docs/dust-trial-notes.md` (xlabs-io-phx) — the spec we built this from

## Revision history

- **r2 (2026-05-11).** Implementing the SDK pre-work surfaced that **B
  (ETS-backed outbox) is not actually blocking v1**. Pre-work A made all
  write ops sync; that means the `Repo.insert(cs)` user blocks on a
  GenServer.call until ack. SyncEngine's `pending_ops` map is populated
  *before* `send_to_connection` runs, and on the next `:connected`
  transition it resends every pending op (`sync_engine.ex:499–503`).
  So a Connection process restart loses its outbox but SyncEngine
  re-asks via the resend mechanism, and the user's blocked call sees
  the eventual ack normally. ETS-backed durability would only matter
  if SyncEngine *itself* crashes — much rarer than a Slipstream
  reconnect. Demoted to deferred enhancement; revisit if a real
  "writes lost" report comes in. Six SDK pre-work items remain
  blocking: A, C, D, E, F, G.

- **r1 (2026-05-10).** External review surfaced ten substantive corrections —
  most importantly that several items the design treated as straightforward
  in the SDK (subtree reads, subtree cache invalidation, public unsubscribe,
  committed-event delivery for own writes) don't yet exist. Pre-work list
  expanded from 3 to 7 SDK items, all blocking v1. Schema macro grew an
  explicit `required:` opt because Ecto's `validate_required` is a runtime
  check with no introspectable metadata. Insert/update semantics
  re-described as "validated upserts" — Dust writes are upserts at the
  wire level and there's no honest way to fake `INSERT … ON CONFLICT FAIL`
  without subtree CAS. Other corrections: transport detection via explicit
  config (the `Process.whereis(Dust.Supervisor)` heuristic is wrong because
  `use Dust` names the supervisor as the facade module), `delete_all`
  returns `store_seq` not count, `embedded_dump` quirks documented, HEAD
  endpoint demoted to optimization with a documented fallback.

## Why

A Phoenix engineer reading the `xlabs-io-phx` codebase shouldn't need to learn
a new abstraction to read and write Dust state. They already know
`Ecto.Schema`, `Ecto.Changeset`, and the Repo idiom. dust_ecto delivers that
on top of Dust's flat KV model.

The xlabs trial built `Xlabs.Dust.Schema` + `Xlabs.Dust.Repo` ad-hoc, hit four
sharp footguns in the first hour, and concluded:

> The thing that would 10× dust's adoption among Phoenix shops, more than any
> feature: an official `dust_ecto` package that ships `Dust.Schema` and
> `Dust.Repo` along the lines of what this trial built, with the workarounds
> baked in, the silent-success bug fixed, and a `subscribe/2` callback wired to
> `Phoenix.PubSub`.

This doc is the design for that package.

## Non-goals

- Not a relational layer. No `has_many`, no `belongs_to`, no `preload`.
- Not a migration framework. Dust has no schema to migrate.
- Not a query DSL. No `from`, no `where`. The only retrievals are
  "all of a schema," "by slug," and pattern subscriptions.
- Not a caching layer. Coupling caching to the Repo proved wrong in the
  trial. Caching belongs in context modules.

## Package & namespace

- Separate hex package: `dust_ecto`
- Lives at `sdk/elixir_ecto/` in this monorepo
- Depends on `:dust`, `:ecto`, `:req`
- Requires **Elixir `~> 1.18`** so it can use stdlib `JSON`. The `:dust`
  SDK currently targets `~> 1.17` and will continue to use Jason until
  the SDK itself bumps. dust_ecto's higher floor is acceptable because
  it's a new package; users not on 1.18 can stay on the SDK alone.
- Public modules: `DustEcto.Schema`, `DustEcto.Repo`, `DustEcto.Error`
- Naming follows `phoenix_ecto` / `ecto_sql` convention

```
sdk/elixir_ecto/
  mix.exs
  lib/dust_ecto.ex                 # version + umbrella
  lib/dust_ecto/schema.ex          # use macro
  lib/dust_ecto/repo.ex            # public API
  lib/dust_ecto/error.ex           # struct + kinds
  lib/dust_ecto/transport.ex       # behaviour
  lib/dust_ecto/transport/sdk.ex   # delegates to Dust.put / Dust.on / ...
  lib/dust_ecto/transport/http.ex  # Req-based, no realtime
  test/...
```

## Schema macro

```elixir
defmodule MyApp.Reading.Link do
  use DustEcto.Schema,
    prefix: "links",                # required
    required: [:slug, :title, :url] # required-fields metadata
    # mode: :map                    # default

  embedded_schema do
    field :title, :string
    field :url, :string
    field :note, :string
    field :added_at, :utc_datetime
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:slug, :title, :url, :note, :added_at])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end
```

The `use DustEcto.Schema, ...` macro:

1. Calls `use Ecto.Schema` + `import Ecto.Changeset`
2. Sets `@primary_key {:slug, :string, autogenerate: false}`
3. Defines `__dust_prefix__/0` returning `"links"`
4. Defines `__dust_mode__/0` returning `:map` or `:flat`
5. Defines `__dust_field_names__/0` for fast field iteration without
   re-asking Ecto reflection
6. Defines `__dust_required_fields__/0` from the `required:` opt.
   **This is necessary** — Ecto's `validate_required` is a runtime
   check with no introspectable metadata, so dust_ecto can't recover
   the required-fields list from the schema otherwise. The same list
   is used by the user's changeset *and* by `Repo.all`'s read-time
   guard, so they stay in sync.
7. Provides `validate_dust_slug/2` — rejects empty, dot-bearing, or
   slash-bearing slugs (closes trial gap #10)
8. Reserves `__dust_store__/0` for v1.1+ multi-store support; v1
   pulls store name from `Application.fetch_env!(:dust_ecto, :store)`

Two opinionated exclusions:

- **No timestamps macro.** Users declare `:inserted_at` / `:updated_at`
  as ordinary fields and set them in their changeset. Magic timestamps
  would need extra writes; not worth the complexity.
- **No associations.** Out of scope. Hand-rolled lookups are fine.

## Storage shape

Two modes, picked per-schema:

### `mode: :map` (default)

One PUT per record, body = the dumped struct as a JSON map. Server
flattens to leaf entries server-side automatically.

```
Repo.insert(%Link{slug: "foo", title: "x", url: "y"})
  → PUT links.foo  body: {"title":"x","url":"y"}
     (1 write, server flattens to 2 leaf entries)

Repo.update(cs)  # cs.changes = %{note: "new"}
  → PUT links.foo  body: {"title":"x","url":"y","note":"new"}
     (1 write, replaces whole subtree)
```

**`Ecto.embedded_dump/2` quirks we explicitly handle:**

- **`:slug` is always dropped from the body.** It's the primary key,
  encoded in the URL path; never serialized in the value. Without
  this filter, every record would have a redundant `"slug"` field
  that gets flattened to `<prefix>.<slug>.slug`, polluting the
  store.
- **`nil` field values are emitted as JSON `null` in the body**,
  not omitted. This matches JSON semantics and Phoenix changeset
  behavior. Storing `null` is a deliberate value, not a deletion.
  Users who want a field gone delete-and-recreate the record.
- **Atom keys are fine.** Stdlib `JSON.encode!/1` handles
  atom-keyed maps natively. (This is the failure mode that hit
  xlabs's hand-rolled `write_struct` — gap #4.)

Atomic. Simple. No orphans. **Trade-off:** subtree CAS isn't yet
supported by the server (capver 2 is leaf-only), so two concurrent
writers to different fields of the same record will clobber. For
config-shaped data this is fine.

### `mode: :flat`

What xlabs built. One PUT per field on insert; on update, one PUT
per changed field. `nil` values write JSON `null` at that field's
path (consistent with map mode); users wanting a field gone
delete-and-recreate the whole record.

```
Repo.insert(%Link{slug: "foo", title: "x", url: "y"})
  → PUT links.foo.title  "x"
  → PUT links.foo.url    "y"

Repo.update(cs)  # cs.changes = %{note: "new"}
  → PUT links.foo.note  "new"
```

Per-field revisions. Concurrent-friendly: two writers editing different
fields don't clobber. **Trade-off:** orphan records visible mid-write
(documented; not papered over).

## Repo — reads

```elixir
DustEcto.Repo.all(Link)              # {:ok, [%Link{}, ...]}
DustEcto.Repo.get(Link, "x-is-real") # {:ok, %Link{}} | {:error, :not_found}
DustEcto.Repo.get!(Link, "x-is-real") # %Link{} or raises
DustEcto.Repo.stream(Link)           # Stream of %Link{}, lazy across pages
DustEcto.Repo.exists?(Link, "slug")  # true | false
```

- **Pagination.** `all/1` walks every page until `next_cursor: nil`.
  No silent truncation (trial gap #8).
- **`stream/1`** is `Stream.resource`-shaped, lazy.
- **`exists?/2`** is the cheapest existence probe available:
  - SDK mode: in-process cache lookup, sub-ms (after the SDK pre-work
    item D — subtree-aware reads — lands).
  - HTTP mode: tries `HEAD /api/.../entries/<prefix>/<slug>` first
    (200 / 404 / 405). On 405 (no HEAD route on this server version),
    falls back to
    `GET /entries?pattern=<prefix>.<slug>.**&select=keys&limit=1`.
    The HEAD route is a server-side polish item, not blocking — the
    fallback works fine.
- **Required-fields guard on read.** Read flow: gather descendant
  entries, **synthesize `:slug` from the URL path before validating** —
  `:slug` is required but is never stored in the body, so without
  this step every record would fail the guard. After slug injection,
  any record missing a field listed in `__dust_required_fields__/0`
  is silently dropped from `all/1`, with a `Logger.warning` listing
  the slug, missing fields, and unrecognized fields so devs can grep
  their logs (trial gap #5). The required list is the same one the
  user's changeset uses, so guard and validation stay in sync.
- **`Repo.get/2` in map mode** depends on SDK pre-work item D. After
  the server flattens a map-mode write, the entries live at
  `<prefix>.<slug>.<field>` — there is no exact-path leaf at
  `<prefix>.<slug>`. The SDK's current `Dust.get/2` and `Dust.entry/2`
  both do exact-path lookups only; in HTTP mode the server does
  subtree assembly automatically (`sync.ex:111` `assemble_subtree`),
  but the SDK doesn't. Without the SDK fix, SDK-mode reads of map-mode
  records would always miss. Pre-work item D fixes this in the SDK.
  Until it lands, dust_ecto's SDK transport can fall back to
  `Dust.enum(store, "<prefix>.<slug>.**")` and assemble client-side,
  but that's slower and has different cache-coherence properties — so
  D is blocking, not just polish.
- **No `get_by/2`.** Implies secondary indexes; Dust has none.

## Repo — writes

```elixir
DustEcto.Repo.insert(%Link{...} |> Link.changeset(attrs))
DustEcto.Repo.insert!(cs)
DustEcto.Repo.update(link |> Link.changeset(attrs))
DustEcto.Repo.delete(struct_or_changeset)
DustEcto.Repo.delete(Link, "slug")     # convenience
DustEcto.Repo.delete_all(Link)         # nukes the whole prefix
```

All return `{:ok, struct}` / `{:ok, %{store_seq: n}}` for `delete_all`, or
`{:error, %Ecto.Changeset{}}` / `{:error, %DustEcto.Error{}}`.

**Honest contract: writes are upserts.** Dust has no
"insert-only-if-absent" wire op, no subtree CAS for atomic
read-modify-write, and no batch-write primitive yet. We don't paper
over this — `Repo.insert` and `Repo.update` are both **validated upserts**:
they run the changeset, then write. There is no "did the record
already exist" check. If you want INSERT-or-fail semantics, do a
`Repo.exists?/2` check before `Repo.insert` and accept that another
writer can race you in between. If you need that race closed,
`batch_write` upstream (server pre-work) plus subtree CAS upstream
are the lever.

- **Insert / update — map mode.** One PUT. Drop `:slug` from the
  dumped struct (it's encoded in the URL path). `nil` fields emit
  as JSON `null`. `Ecto.embedded_dump(struct, :json)` → atom-keyed
  map → `JSON.encode!/1` (which handles atoms). Trial gap #4
  closed by always counting writes; if zero, `{:error, :nothing_to_write}`.
- **Insert / update — flat mode.** N PUTs, sequential, deterministic
  ordering. Same `:slug` exclusion. `nil` is written as JSON `null`
  at the field's path (consistent with map mode); users wanting a
  field gone delete-and-recreate the whole record. Same zero-write
  guard.
- **`delete/1`.** Single `DELETE /entries/<prefix>/<slug>` — the
  endpoint shipped at commit `ac47fbb` clears subtrees in one call.
  In SDK mode, requires pre-work item E so the local cache also
  drops descendants on the delete event.
- **`delete_all/1`.** Single `DELETE /entries/<prefix>`. Returns
  `{:ok, %{store_seq: n}}` — the server's DELETE endpoint reports
  the post-delete `store_seq`, not a count of removed rows. Returning
  a count would require a pre-list, which is expensive and race-prone.
- **No `insert_all`.** Server's `entries.batch` endpoint is read-only;
  a write-batch primitive is upstream pre-work (see Section "Server
  pre-work").

## Repo — subscribe

```elixir
DustEcto.Repo.subscribe(Link, fn
  {:upserted, %Link{} = link} -> ...
  {:deleted, slug}            -> ...
end)
# returns {:ok, ref} | {:error, :not_supported}

DustEcto.Repo.subscribe_raw(Link, fn raw_op -> ... end)

DustEcto.Repo.unsubscribe(ref)
```

**Two states, not four.** `:upserted` and `:deleted`. Not
`:inserted`/`:updated` — from a subscriber's point of view, every
observation is post-state. Forcing the distinction would require
per-subscriber persistent state. We don't.

**Map mode** is trivial: one op per record write.
**Flat mode** emits one upsert event per leaf; predictable, faithful,
and the user's idempotent handler doesn't care.

**SDK mode** delegates to `Dust.on(store, "<prefix>.**", callback,
mode: :committed)`. Reassembly happens in our wrapper before calling
the user's callback. Two SDK pre-work items are blocking here:

- **Pre-work F** — public `Dust.off/1` (or `Dust.unsubscribe/1`) so
  `DustEcto.Repo.unsubscribe/1` can actually unhook a callback. The
  current SDK has no public way to remove a subscription.
- **Pre-work G** — a `mode: :committed | :all | :optimistic` opt on
  `Dust.on/4`. Today the SDK fires optimistic `committed: false`
  events for own writes (`sync_engine.ex:752`) and *suppresses* the
  committed echo of own writes (`sync_engine.ex:666` —
  `unless was_pending`). For dust_ecto's contract, the user wants
  exactly one event per write that carries `store_seq`. Default of
  `:all` preserves today's behavior; dust_ecto opts into
  `:committed`.

**HTTP mode** returns `{:error, :not_supported}`. We do not fake
realtime via polling.

**`subscribe_raw/2`** is the escape hatch for users who want per-leaf
provenance — receives `%{op:, path:, value:, store_seq:}` exactly.

## Transport — auto-detect

A behaviour with two implementations. Picked at call time, but
**not** by checking `Process.whereis(Dust.Supervisor)` — the
recommended `use Dust, otp_app: ...` pattern names the supervisor
as the **facade module** (e.g. `MyApp.Dust`), not `Dust.Supervisor`.
A naive whereis check would always miss in real apps.

Detection in priority order:

1. **Explicit config** wins. `config :dust_ecto, dust_facade: MyApp.Dust`
   tells dust_ecto exactly which facade to call into. This is the
   recommended setup.
2. **Registry probe** as fallback. dust_ecto looks up the configured
   store in `Dust.SyncEngineRegistry`; if a SyncEngine is registered
   for that store, SDK mode is in play.
3. **Otherwise** fall through to HTTP mode.

```elixir
defp transport do
  cond do
    facade = Application.get_env(:dust_ecto, :dust_facade) ->
      {DustEcto.Transport.SDK, facade}

    sdk_running?() ->
      {DustEcto.Transport.SDK, Dust}

    true ->
      {DustEcto.Transport.HTTP, nil}
  end
end

defp sdk_running? do
  store = Application.fetch_env!(:dust_ecto, :store)

  case Process.whereis(Dust.SyncEngineRegistry) do
    nil -> false
    _ -> Registry.lookup(Dust.SyncEngineRegistry, store) != []
  end
end
```

**WS (SDK) is the recommended primary in Elixir.** HTTP is the
stateless fallback for one-shot scripts, release tasks, and
serverless contexts.

The behaviour:

```elixir
@callback list(store, pattern, opts) ::
            {:ok, %{items: [...], next_cursor: String.t() | nil}} | {:error, term}
@callback get(store, path) :: {:ok, map} | {:error, :not_found | term}
@callback put(store, path, value, opts) ::
            {:ok, %{store_seq: integer}} | {:error, term}
@callback delete(store, path, opts) ::
            {:ok, %{store_seq: integer}} | {:error, term}
@callback subscribe(store, pattern, callback) ::
            {:ok, ref} | {:error, :not_supported}
```

## Configuration

### HTTP-only mode

```elixir
config :dust_ecto,
  store: System.get_env("DUST_STORE"),
  base_url: System.get_env("DUST_BASE_URL", "https://dustlayer.io"),
  token: System.get_env("DUST_TOKEN")
```

No supervisor child. dust_ecto is stateless in HTTP mode.

### SDK mode

```elixir
# config/runtime.exs
config :myapp, MyApp.Dust,
  url: "wss://dustlayer.io/ws/sync",
  token: System.get_env("DUST_TOKEN"),
  stores: [System.get_env("DUST_STORE")],
  cache: {Dust.Cache.Memory, []}

config :dust_ecto,
  store: System.get_env("DUST_STORE"),
  dust_facade: MyApp.Dust

# lib/myapp.ex
defmodule MyApp.Dust do
  use Dust, otp_app: :myapp
end

# lib/myapp/application.ex
children = [
  MyApp.Dust,
  ...
]
```

`config :dust_ecto, :store` is the default store name. v1 is
single-store; v1.1+ adds `__dust_store__/0` reflection on the
schema for multi-store. Token stays a single global value.

`config :dust_ecto, :dust_facade` lets dust_ecto find the SDK at
its actual registered name. Without this, dust_ecto falls back to
the registry probe described above.

## Error model

- `Repo.insert(invalid_changeset)` → `{:error, %Ecto.Changeset{}}` —
  exact Ecto shape.
- Transport failures → `{:error, %DustEcto.Error{kind: :network |
  :http | :conflict | :timeout | :unauthorized | ..., detail: term,
  retryable?: bool}}`. Single struct, machine-readable `kind`.
  No raw tuples leaking to user code.

## Telemetry

```
[:dust_ecto, :query, :start]
[:dust_ecto, :query, :stop]
[:dust_ecto, :query, :exception]
```

Measurements: `%{schema:, op:, transport:, store:, duration_native:}`.
Same shape as `Ecto.Repo` events so existing dashboards work.

## Workarounds shipped

| Trial gap | What dust_ecto does |
|---|---|
| #1 — `Req.put(url, json: nil)` empty body | Body is always a populated JSON value: a map in map mode, an explicit JSON null literal in flat mode when a field is `nil`. Never `nil` to Req. Non-issue by construction. |
| #2 — multi-key transactionality | Map mode = atomic 1 PUT. Flat mode documents the partial-write window. |
| #3 — no real DELETE | Already shipped upstream (`ac47fbb`). |
| #4 — atom-keyed dump silently writes zero | Always count writes; `{:error, :nothing_to_write}` if zero. |
| #5 — no schema enforcement | `Repo.all` skips & logs orphan records by slug. |
| #6 — no exists probe | `Repo.exists?` uses HEAD (HTTP) or cache (SDK). |
| #8 — pagination not iterated | `Repo.all` walks all pages; `Repo.stream` for lazy. |
| #10 — slug containing `.` mis-shapes | `validate_dust_slug/1` baked into the macro. |

## Pre-work in `:dust` (blocks dust_ecto v1)

Seven SDK changes land **before** dust_ecto v1. Each is a focused
PR against the SDK, mostly ~50–150 LOC.

| # | Item | Why |
|---|---|---|
| A | **Sync write semantics for all write ops.** Today only `Dust.put/4` (4-arg variant) defers reply until server ack. `delete`, `merge`, `increment`, `add`, `remove` all reply `:ok` immediately. Add the deferred-reply path to all of them, gated on an `opts` arg the same way. | `Repo.delete(struct)` returning `{:ok, _}` must mean server-acked, not "queued in the optimistic cache." |
| ~~B~~ | ~~ETS-backed outbox~~ — **deferred** (see r2 revision note). SyncEngine's `pending_ops` already provides Connection-restart durability via the resend on `:connected`; full ETS durability only matters if SyncEngine itself crashes, which is much rarer. Revisit if real "writes lost" reports come in. | (deferred) |
| C | **Connection observability** — `Dust.Connection.connected?/0` plus `:telemetry.execute([:dust, :connection, :state_change], %{}, %{from:, to:})` on every transition. | LiveView users need to react to disconnects; dust_ecto needs a clean probe for HTTP-fallback decisions. |
| D | **SDK subtree-aware reads + cache canonicalization on map writes.** Two paired changes: (1) `Dust.get/2` and `Dust.entry/2` are exact-path-only today (`sync_engine.ex:191`, `sync_engine.ex:457`); the server does subtree assembly server-side (`sync.ex:111` `assemble_subtree`), the SDK doesn't, so map-mode `<prefix>.<slug>` reads must fall back to assembling from descendants. (2) The SDK's optimistic write path (`sync_engine.ex:753`) and server-event apply path (`sync_engine.ex:632`) both write a plain-map value at the exact path verbatim. The server flattens to leaves, so cache-after-own-write has the root-map row, and cache-after-event-echo *adds* the leaf rows on top — divergent shapes. SDK must canonicalize plain-map `set` ops the same way the server does: clear descendants, write flattened leaves, no exact root leaf. Without this, `get`/`all`/`subscribe` results differ depending on whether data came from a live write, catch-up, or snapshot. | dust_ecto `Repo.get(Link, "foo")` in SDK mode would return `:not_found` without (1) and would return inconsistent shapes depending on data path without (2). Map mode fundamentally requires both. |
| E | **SDK subtree cache invalidation.** Today `cache.delete(target, store, path)` removes only the exact path (`cache/memory.ex:135`, `cache/ecto.ex:123`). The server's DELETE endpoint clears descendants, but the SDK cache and the server-event handler at `sync_engine.ex:633` both call exact-path delete. After `Repo.delete(record)` the descendants would linger in cache, returning stale data. | dust_ecto `Repo.delete` and `Repo.delete_all` both clear subtrees; the local view has to follow. |
| F | **Public unsubscribe API.** `Dust.on/4` returns a ref but the SDK has no `Dust.off/1` or `Dust.unsubscribe/1`. dust_ecto exposes `Repo.unsubscribe/1`; without an SDK-side counterpart, the underlying registration leaks. | Subscriptions are first-class in the dust_ecto API; we can't ship them without a removal path. |
| G | **`mode:` opt on `Dust.on/4`** — `:committed | :all | :optimistic`. Today the SDK fires optimistic `committed: false` events for own writes (`sync_engine.ex:752`) and *suppresses* the committed echo of own writes (`sync_engine.ex:666`). dust_ecto's `:upserted`/`:deleted` events need exactly one delivery per write, with `store_seq`, even for own writes. Default `:all` preserves today's behavior. | Without it, dust_ecto can't deliver `{:upserted, %Link{}}` reliably with a `store_seq` for own writes. |

A and C are the original blocking items; B was demoted in r2 (see
revision note); D–G surfaced from the r1 review and are all blocking.

**Facade delegations.** `Dust.Instance` (the `use Dust` facade module
generator at `sdk/elixir/lib/dust/instance.ex`) currently delegates
the existing 3-arg APIs. Items A and F–G grow new arities and new
functions on the SDK; the facade must grow matching delegations so
`MyApp.Dust.delete/3`, `MyApp.Dust.merge/4`, `MyApp.Dust.increment/4`,
`MyApp.Dust.add/4`, `MyApp.Dust.remove/4`, `MyApp.Dust.enum/3`,
`MyApp.Dust.range/4`, `MyApp.Dust.entry/2`, `MyApp.Dust.off/1`, and
`MyApp.Dust.unsubscribe/1` all work. Otherwise dust_ecto's
`dust_facade: MyApp.Dust` config can't reach the new APIs — only
calls into the global `Dust` module would.

## Server pre-work (parallel; not blocking dust_ecto v1)

These improve the *raw* HTTP API for any client (not just dust_ecto).
Tracked separately:

- **HEAD /api/.../entries/{path}** — cheap exists probe. S3-shaped.
  Optional optimization for `Repo.exists?`; HTTP transport falls
  back to `?pattern=…&select=keys&limit=1` when HEAD is unavailable.
  Not blocking v1.
- **POST /api/.../entries/batch_write** — atomic multi-key write.
  Closes trial gap #2 at the source. Would let dust_ecto add
  `Repo.insert_all` and `Repo.transaction`. Not blocking v1.
- Several smaller error-message and docs polish items
  (`select=prefixes` clarity, empty-body hint, `/subscribe` stub).

## Testing strategy

Three layers:

1. **Unit — transport-mocked.** Each `Repo` function tested against a
   mock implementing `DustEcto.Transport`. Fast, hermetic.
2. **Integration — against a running Dust server.** Boots the
   umbrella's Dust app in-test (similar to existing
   `entries_api_controller_test.exs`), creates a store + token,
   runs Repo operations through both transports.
3. **Dogfooding — rebuild xlabs.** Port `Xlabs.Reading.Link` line-by-line
   to dust_ecto, run xlabs-io-phx against the new package on a branch.
   The most important test: if porting requires more than a deps
   swap and an import rename, the design failed.

Dogfooding milestones (each gates the next):

- (a) Replace `Xlabs.Dust.Client` → dust_ecto HTTP transport
- (b) Replace `Xlabs.Dust.Schema` → `DustEcto.Schema`
- (c) Replace `Xlabs.Dust.Repo` → `DustEcto.Repo`
- (d) Switch from HTTP to SDK transport (boot `MyApp.Dust`)
- (e) Add a LiveView using `Repo.subscribe` for live-update

Milestone (e) is the README closer.

## What we're explicitly NOT building in v1

- ❌ `Repo.transaction/1` — depends on upstream `batch_write`
- ❌ Repo-layer caching — belongs in context modules
- ❌ Preload / associations
- ❌ Migration layer
- ❌ Bang-variant explosions beyond `get!`/`insert!`

## Open questions (after v1)

- Per-schema `__dust_store__/0` for multi-store support
- Subtree CAS (depends on capver 3)
- `Repo.transaction/1` once `batch_write` lands upstream
- Phoenix.PubSub bridge as a built-in convenience (vs. user-written
  one-line callback)
