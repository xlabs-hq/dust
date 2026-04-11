# Dust Elixir SDK: Hex Package + LiveDashboard Plugin

## Goal

Ship the Elixir SDK as a single hex package (`dust`) that developers add to their mix.exs like Oban. Include a LiveDashboard page plugin for observability. The protocol library is inlined — no second package to coordinate.

## Constraints

**Single instance per VM.** The supervisor uses global names for Connection, SyncEngineRegistry, and ConnectionRegistry. One `use Dust, otp_app: :my_app` per application. This is the same model as Oban, Ecto.Repo, and Phoenix.PubSub — you name your instance and it registers globally. Multi-instance support is out of scope.

## Package Structure

One hex package. Protocol at the core, Phoenix/Ecto features opt-in via optional deps.

```
lib/
  dust.ex                        # Public API, __using__ macro
  dust/
    # Core (no optional deps)
    protocol/
      codec.ex                   # MessagePack/JSON encode/decode
      glob.ex                    # Glob compile/match
      message.ex                 # Wire message types
      op.ex                      # Operation types
      path.ex                    # Path parsing
    connection.ex                # Slipstream WebSocket client
    sync_engine.ex               # GenServer per store
    cache.ex                     # Behaviour
    cache/memory.ex              # In-process cache (always available)
    callback_registry.ex         # Pattern-matched subscriptions
    callback_worker.ex           # Per-subscription process
    file_ref.ex                  # Lazy file loading
    supervisor.ex                # Supervision tree
    instance.ex                  # use Dust, otp_app: :my_app
    testing.ex                   # Test helpers
    activity_buffer.ex           # ETS ring buffer for dashboard

    # Opt-in (compile-guarded, see below)
    cache/ecto.ex                # requires :ecto_sql
    pubsub_bridge.ex             # requires :phoenix_pubsub
    subscriber.ex                # requires :phoenix_pubsub
    subscriber_registrar.ex      # requires :phoenix_pubsub
    dashboard.ex                 # requires :phoenix_live_dashboard

  mix/tasks/
    dust.install.ex              # mix dust.install
    dust.gen.migration.ex        # mix dust.gen.migration

priv/
  templates/
    dust.gen.migration/
      migration.exs.eex          # Migration template
```

### Dependencies

**Required:**
- `slipstream` (~> 1.2) — WebSocket client
- `msgpax` (~> 2.4) — MessagePack
- `jason` (~> 1.4) — JSON
- `decimal` (~> 2.0) — Decimal type
- `req` (~> 0.5) — HTTP client for file downloads

**Optional:**
- `ecto_sql` (~> 3.10) — Ecto cache adapter, mix tasks
- `phoenix_pubsub` (~> 2.0) — PubSub bridge, subscribers
- `phoenix_live_dashboard` (~> 0.8) — Dashboard page plugin
- `phoenix_live_view` (~> 1.0) — Required by dashboard

### Hex Package Config

```elixir
defp package do
  [
    description: "Reactive global state for Elixir apps",
    licenses: ["MIT"],
    links: %{"GitHub" => "https://github.com/jamestippett/dust"},
    files: ~w(lib priv mix.exs README.md LICENSE)
  ]
end
```

The `priv/` directory is required — `mix dust.gen.migration` loads its template from `priv/templates/`.

### Compile Isolation for Optional Deps

Modules that depend on optional libraries are wrapped in compile-time guards so they only compile when the dep is present. This is the standard Elixir pattern used by Oban, Swoosh, and Ecto itself.

```elixir
# cache/ecto.ex
if Code.ensure_loaded?(Ecto.Query) do
  defmodule Dust.Cache.Ecto do
    import Ecto.Query
    # ...
  end
end

# subscriber.ex
if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Dust.Subscriber do
    # ...
  end
end

# dashboard.ex
if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Dust.Dashboard do
    use Phoenix.LiveDashboard.PageBuilder
    # ...
  end
end

# mix/tasks/dust.gen.migration.ex
if Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.Dust.Gen.Migration do
    # ...
  end
end
```

A bare consumer app with no Ecto or Phoenix deps compiles and runs — it gets core protocol, WebSocket sync, memory cache, and callbacks. Adding `ecto_sql` unlocks the Ecto adapter and mix tasks. Adding `phoenix_live_dashboard` unlocks the dashboard tab.

## Protocol Inlining

The five protocol modules move from `protocol/elixir/lib/dust_protocol/` into the SDK as `Dust.Protocol.*`:

| Source (`DustProtocol.*`) | Target (`Dust.Protocol.*`) |
|---------------------------|---------------------------|
| `DustProtocol.Codec` | `Dust.Protocol.Codec` |
| `DustProtocol.Glob` | `Dust.Protocol.Glob` |
| `DustProtocol.Message` | `Dust.Protocol.Message` |
| `DustProtocol.Op` | `Dust.Protocol.Op` |
| `DustProtocol.Path` | `Dust.Protocol.Path` |

All SDK references (6 call sites in callback_registry, cache/ecto, cache/memory) change from `DustProtocol.Glob` to `Dust.Protocol.Glob`.

The server keeps its own path dep on `protocol/elixir/` using the `DustProtocol.*` namespace.

### Preventing Protocol Drift

The protocol source in `protocol/elixir/` remains the canonical copy. The SDK inlines a snapshot. To catch drift:

1. **Shared test fixtures.** A `protocol/spec/fixtures/` directory contains test vectors — known inputs and expected encoded outputs for each operation type, glob pattern, and message format. Both the server's `DustProtocol` tests and the SDK's `Dust.Protocol` tests run against the same fixtures.
2. **CI check.** A CI step diffs the protocol source files. If `protocol/elixir/lib/` has changed without a corresponding update in `sdk/elixir/lib/dust/protocol/`, the build fails. Simple file-hash comparison — no runtime coupling.

## Dashboard Introspection API

The dashboard needs data that the current SyncEngine, Connection, and Cache APIs don't expose. These additions are required before implementing the dashboard.

### Connection Introspection

`Dust.Connection` gains state tracking and a query API:

```elixir
# New assigns stored on the socket:
assign(:url, url)              # already passed in, just not retained
assign(:connected_at, nil)     # set to DateTime.utc_now() on handle_connect
assign(:status, :disconnected) # :connected | :disconnected | :reconnecting

# New public function:
def info(conn_pid) do
  GenServer.call(conn_pid, :info)
  # => %{status: :connected, url: "wss://...", device_id: "dev_xxx",
  #      connected_at: ~U[...], uptime_seconds: 1234}
end
```

### SyncEngine Introspection

`Dust.SyncEngine.status/1` is extended:

```elixir
def handle_call(:status, _from, state) do
  entry_count = state.cache.count(state.cache_target, state.store)

  status = %{
    connection: state.status,
    last_store_seq: state.last_store_seq,
    pending_ops: map_size(state.pending_ops),
    entry_count: entry_count,
    store: state.store
  }
  {:reply, status, state}
end
```

### Cache Behaviour: `count/2` and `browse/4`

Two new callbacks added to `Dust.Cache`:

```elixir
@callback count(target, store :: String.t()) :: non_neg_integer()

@callback browse(target, store :: String.t(), opts :: keyword()) ::
            {entries :: [{String.t(), term(), String.t(), integer()}], cursor :: term() | nil}
```

`browse/4` options:
- `pattern:` — glob filter (default `"**"`)
- `cursor:` — opaque pagination cursor (default `nil` for first page)
- `limit:` — page size (default 50)
- `sort:` — `:path_asc` (default) or `:seq_desc`

**Ecto adapter** implements `browse` as a keyset-paginated query (`WHERE path > cursor ORDER BY path LIMIT N`), not a full table scan. The glob filter is applied in SQL where possible (`LIKE` prefix from the non-wildcard prefix of the pattern), with a post-filter for complex globs.

**Memory adapter** implements `browse` by sorting the map entries and slicing. Acceptable for dev/test — memory stores are small.

Both return `{entries, next_cursor}` where `next_cursor` is `nil` when there are no more pages.

### Activity Buffer

`Dust.ActivityBuffer` is a new module — a thin wrapper around a named ETS table. The SyncEngine appends to it on each processed event. Capped at 100 entries per store via circular index.

```elixir
defmodule Dust.ActivityBuffer do
  # Started by Dust.Supervisor, before SyncEngines
  def start_link(opts)

  def append(store, entry)
  # entry: %{timestamp, store, path, op, source, seq}

  def recent(store, limit \\ 100)
  # => [%{...}, ...]  newest first
end
```

This is the one new ETS table. It exists because the dashboard needs a recent-activity view that doesn't require calling into SyncEngine GenServers on every refresh.

## Server Impact

None. The server keeps `{:dust_protocol, path: "../../protocol/elixir"}` in its mix.exs and uses `DustProtocol.*` modules. The server never depends on the SDK package.

## What This Does Not Include

- **Standalone LiveView dashboard** — LiveDashboard tab only. Graduate to standalone if there's demand.
- **Callback/subscriber inspection** — internal plumbing, not useful for dog-fooding.
- **Metrics or charts** — no telemetry history to graph yet.
- **Write/replay tools in dashboard** — the CLI handles this.
- **Multi-instance support** — one Dust supervisor per VM, like Oban.

## Testing Requirements

These tests validate the packaging and integration, not the sync engine (already covered):

1. **Bare consumer compile test.** A mix project that depends on `{:dust, path: "..."}` with no Ecto or Phoenix deps. Must compile and run `Dust.Cache.Memory` operations.
2. **Install/migration test.** Run `mix dust.install` and `mix dust.gen.migration` in a fresh Phoenix project, verify generated files exist and compile.
3. **Protocol compatibility.** Both `DustProtocol` (server) and `Dust.Protocol` (SDK) run against shared test fixtures in `protocol/spec/fixtures/`. CI fails if fixtures diverge.
4. **Dashboard browse pagination.** Seed a store with 500 entries, page through with `browse/4`, verify stable ordering, no duplicates, correct cursor termination.
