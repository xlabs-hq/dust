# Dust Elixir SDK: Hex Package + LiveDashboard Plugin

## Goal

Ship the Elixir SDK as a single hex package (`dust`) that developers add to their mix.exs like Oban. Include a LiveDashboard page plugin for observability. The protocol library is inlined — no second package to coordinate.

## Package Structure

One hex package. Protocol at the core, Phoenix/Ecto features opt-in via optional deps.

```
lib/
  dust.ex                        # Public API, __using__ macro
  dust/
    # Core (no optional deps)
    protocol/
      codec.ex                   # MessagePack/JSON encode/decode
      types.ex                   # Type definitions, detection
      path.ex                    # Path parsing, glob matching
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

    # Opt-in (optional deps)
    cache/ecto.ex                # requires :ecto_sql
    pubsub_bridge.ex             # requires :phoenix_pubsub
    subscriber.ex                # requires :phoenix_pubsub
    subscriber_registrar.ex      # requires :phoenix_pubsub
    dashboard.ex                 # requires :phoenix_live_dashboard
```

### Dependencies

**Required:**
- `slipstream` (~> 1.2) — WebSocket client
- `msgpax` (~> 2.4) — MessagePack
- `jason` (~> 1.4) — JSON
- `decimal` (~> 2.0) — Decimal type
- `req` (~> 0.5) — HTTP client for file downloads

**Optional:**
- `ecto_sql` (~> 3.10) — Ecto cache adapter
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
    files: ~w(lib mix.exs README.md LICENSE)
  ]
end
```

## Protocol Inlining

The protocol modules move from `protocol/elixir/lib/dust_protocol/` into the SDK as `Dust.Protocol.*`. The server keeps its own path dep on `protocol/elixir/` using the `DustProtocol.*` namespace. Two copies, different namespaces, no runtime coordination.

Protocol changes are rare (wire format). When they happen, update both copies. This beats coordinating two hex package releases.

## LiveDashboard Page Plugin

### Setup

One line in the host app's router:

```elixir
live_dashboard "/dev/dashboard",
  additional_pages: [
    dust: Dust.Dashboard
  ]
```

### Architecture

`Dust.Dashboard` implements `Phoenix.LiveDashboard.PageBuilder`. On mount it reads from existing processes — no new GenServers or ETS tables required.

**Data sources:**
- `Dust.Connection` — connection status, server URL, device ID
- `Dust.SyncEngine` — per-store state, cached entry counts, last synced seq
- `Dust.Cache` — entry browsing via the cache adapter's `read_all/3`
- Activity ring buffer — the one new addition (see below)

**Live updates:** Subscribes to PubSub (`dust:*` topics) if available. Falls back to periodic polling on a timer.

### Layout

Four panels on a single page:

**1. Connection bar** (top row)
Status badge (connected / disconnected / reconnecting), server URL, device ID, uptime. Simple key-value display.

**2. Stores table** (below connection bar)
One row per configured store:
- Name
- Entry count (from cache)
- Last synced seq
- Status badge (caught up / catching up / disconnected)

Clicking a store filters the entries browser and activity feed below.

**3. Entries browser** (bottom left)
Cached entries for the selected store:
- Columns: path, value (truncated), type, seq
- Text input for path pattern filter (glob)
- Paginated

**4. Activity feed** (bottom right)
Live-updating list of recent operations:
- Columns: timestamp, store, path, op, source (local/server), seq
- Capped at last 100 entries, newest on top
- New entries highlight briefly on arrival

### Activity Ring Buffer

The SyncEngine appends a summary to a shared ETS table on each processed event. Capped at 100 entries per store using a circular index. The dashboard reads from this table — no GenServer calls on the hot path.

```elixir
# Entry shape
%{
  timestamp: DateTime.t(),
  store: String.t(),
  path: String.t(),
  op: atom(),
  source: :local | :server,
  seq: integer()
}
```

## Server Impact

None. The server keeps `{:dust_protocol, path: "../../protocol/elixir"}` in its mix.exs and uses `DustProtocol.*` modules. The server never depends on the SDK package.

## What This Does Not Include

- **Standalone LiveView dashboard** — LiveDashboard tab only. Graduate to standalone if there's demand.
- **Callback/subscriber inspection** — internal plumbing, not useful for dog-fooding.
- **Metrics or charts** — no telemetry history to graph yet.
- **Write/replay tools in dashboard** — the CLI handles this.
