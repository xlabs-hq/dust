# dust_ecto — design

**Status:** validated, pre-implementation
**Date:** 2026-05-10
**Authors:** James Tippett (with Claude)
**Related:** `docs/dust-trial-notes.md` (xlabs-io-phx) — the spec we built this from

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
- No `:jason` dep — uses stdlib `JSON` (Elixir 1.18+)
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
  use DustEcto.Schema, prefix: "links"   # mode: :map (default)

  embedded_schema do
    field :title, :string
    field :url, :string
    field :note, :string
    field :added_at, :utc_datetime
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:slug, :title, :url, :note, :added_at])
    |> validate_required([:slug, :title, :url])
    |> validate_dust_slug(:slug)
  end
end
```

The `use DustEcto.Schema, prefix: "links"` macro:

1. Calls `use Ecto.Schema` + `import Ecto.Changeset`
2. Sets `@primary_key {:slug, :string, autogenerate: false}`
3. Defines `__dust_prefix__/0` returning `"links"`
4. Defines `__dust_mode__/0` returning `:map` or `:flat`
5. Defines `__dust_field_names__/0` for fast field iteration without
   re-asking Ecto reflection
6. Provides `validate_dust_slug/2` — rejects empty, dot-bearing, or
   slash-bearing slugs (closes trial gap #10)
7. Reserves `__dust_store__/0` for v1.1+ multi-store support; v1
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

Atomic. Simple. No orphans. **Trade-off:** subtree CAS isn't yet
supported by the server (capver 2 is leaf-only), so two concurrent
writers to different fields of the same record will clobber. For
config-shaped data this is fine.

### `mode: :flat`

What xlabs built. One PUT per non-nil field; on update, one PUT per
changed field.

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
  - SDK mode: in-process cache lookup, sub-ms.
  - HTTP mode: a `HEAD /api/.../entries/<prefix>/<slug>` round-trip.
    No body. (Requires the upstream HEAD endpoint to ship — see
    "Pre-work in :dust" below.)
- **Required-fields guard on read.** A record missing required fields
  is silently dropped from `all/1`, but a `Logger.warning` lists the
  slug, missing fields, and unrecognized fields so devs can grep
  their logs (trial gap #5).
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

All return `{:ok, struct}` / `{:ok, count}` for `delete_all`, or
`{:error, %Ecto.Changeset{}}` / `{:error, %DustEcto.Error{}}`.

- **Insert / update — map mode.** One PUT. `Ecto.embedded_dump(struct,
  :json)` → atom-keyed map → `JSON.encode!/1` (which handles atoms).
  Trial gap #4 closed by always counting writes; if zero,
  `{:error, :nothing_to_write}`.
- **Insert / update — flat mode.** N PUTs, sequential, deterministic
  ordering. Same zero-write guard.
- **`delete/1`.** Single `DELETE /entries/<prefix>/<slug>` — the new
  endpoint shipped at commit `ac47fbb` clears subtrees in one call.
- **`delete_all/1`.** Single `DELETE /entries/<prefix>`.
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

**SDK mode** delegates to `Dust.on(store, "<prefix>.**", callback)`.
Reassembly happens in our wrapper before calling the user's callback.

**HTTP mode** returns `{:error, :not_supported}`. We do not fake
realtime via polling.

**`subscribe_raw/2`** is the escape hatch for users who want per-leaf
provenance — receives `%{op:, path:, value:, store_seq:}` exactly.

## Transport — auto-detect

A behaviour with two implementations, picked at call time:

```elixir
defp transport do
  if Process.whereis(Dust.Supervisor),
    do: DustEcto.Transport.SDK,
    else: DustEcto.Transport.HTTP
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
# lib/myapp/application.ex
children = [
  {Dust.Supervisor,
    url: "wss://dustlayer.io/ws/sync",
    token: System.get_env("DUST_TOKEN"),
    stores: [System.get_env("DUST_STORE")],
    cache: {Dust.Cache.Memory, []}},
  ...
]
```

`config :dust_ecto, :store` still applies — that's the default store.
v1 is single-store; v1.1+ adds `__dust_store__/0` reflection on the
schema for multi-store. Token stays a single global value.

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
| #1 — `Req.put(url, json: nil)` empty body | Map mode never writes nil. Flat mode skips nil fields. Non-issue by construction. |
| #2 — multi-key transactionality | Map mode = atomic 1 PUT. Flat mode documents the partial-write window. |
| #3 — no real DELETE | Already shipped upstream (`ac47fbb`). |
| #4 — atom-keyed dump silently writes zero | Always count writes; `{:error, :nothing_to_write}` if zero. |
| #5 — no schema enforcement | `Repo.all` skips & logs orphan records by slug. |
| #6 — no exists probe | `Repo.exists?` uses HEAD (HTTP) or cache (SDK). |
| #8 — pagination not iterated | `Repo.all` walks all pages; `Repo.stream` for lazy. |
| #10 — slug containing `.` mis-shapes | `validate_dust_slug/1` baked into the macro. |

## Pre-work in `:dust` (blocks dust_ecto v1)

These three SDK changes land **before** dust_ecto v1, because the
contract dust_ecto exposes (`{:ok, struct}` = durable) cannot hold
without them:

| # | Item | Why |
|---|---|---|
| A | Sync write semantics for all write ops — `delete/3+opts`, `merge/4`, `increment/4`, `add/4`, `remove/4` need the deferred-reply path that `put/4` already has | `Repo.delete(struct)` returning `{:ok, _}` must mean server-acked |
| B | ETS-backed outbox keyed by `client_op_id`, persisted across `Dust.Connection` process restarts, with on-startup replay | "I wrote it" stays true even through a connection-process crash |
| C | Connection observability — `Dust.Connection.connected?/0` and `:telemetry.execute([:dust, :connection, :state_change], ...)` | LiveView users need to react to disconnects |

Each is a focused PR against the SDK, ~50–150 LOC.

## Server pre-work (parallel; not blocking dust_ecto v1)

These improve the *raw* HTTP API for any client (not just dust_ecto).
Tracked separately:

- **HEAD /api/.../entries/{path}** — cheap exists probe. S3-shaped.
  Removes the `select=keys&limit=1` workaround, makes
  `Repo.exists?` cleaner. Bumped to "ship alongside dust_ecto."
- **POST /api/.../entries/batch_write** — atomic multi-key write.
  Closes trial gap #2 at the source. Would let dust_ecto add
  `Repo.insert_all` and `Repo.transaction`.
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
- (d) Switch from HTTP to SDK transport (boot `Dust.Supervisor`)
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
