# Dust Phase 3: Phoenix Integration + Crystal CLI

## Overview

Two deliverables: a polished Phoenix/Ecto integration layer inside the existing Elixir SDK, and a standalone Crystal CLI that validates the protocol spec from a non-Elixir language.

Reference: [Dust v4 design](2026-03-26-dust-design-v4.md) is the product spec.

## Phoenix Integration

Lives inside `sdk/elixir/` as optional modules. No separate package. Phoenix deps marked `optional: true`.

### Installation

One dependency:

```elixir
{:dust, "~> 0.1"}
```

### Setup (3 steps)

**1. Define your Dust module:**

```elixir
defmodule MyApp.Dust do
  use Dust, otp_app: :my_app
end
```

The `use Dust` macro creates a facade module — all Dust calls go through it (`MyApp.Dust.put/3`, `MyApp.Dust.get/2`, etc.). Internally it wires up the supervision tree: Connection, SyncEngines per store, and subscriber registration.

**2. Configure:**

```elixir
# config/config.exs
config :my_app, MyApp.Dust,
  url: "wss://api.dust.dev/ws/sync",
  stores: ["james/blog", "acme/config"],
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  subscribers: [
    MyApp.Dust.BlogSubscriber,
    MyApp.Dust.ConfigSubscriber
  ]

# config/test.exs
config :my_app, MyApp.Dust, testing: :manual
```

Token comes from `DUST_API_KEY` env var automatically.

**3. Add to supervision tree:**

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyApp.Dust,
  MyAppWeb.Endpoint
]
```

### Installer

`mix dust.install` generates everything in one command:

- Creates the `MyApp.Dust` module
- Adds config entries to `config.exs` and `test.exs`
- Patches the supervision tree in `application.ex`
- Generates the `dust_cache` migration

Igniter support for code patching. Falls back to file generation with instructions if Igniter is not available.

### Migration

```bash
mix dust.install
mix ecto.migrate
```

Creates the `dust_cache` table (same schema as `Dust.Cache.Ecto.Migration`).

### Subscriber Modules

Declarative callback handlers, started automatically from config:

```elixir
defmodule MyApp.Dust.BlogSubscriber do
  use Dust.Subscriber,
    store: "james/blog",
    pattern: "posts.*"

  @impl true
  def handle_event(event) do
    MyApp.Blog.rebuild_index(event.path, event.value)
    :ok
  end
end
```

**How it works:**
- `use Dust.Subscriber` declares store and glob pattern at compile time
- The Dust supervisor reads the `subscribers` list from config
- For each subscriber, it registers via `Dust.on/3` with the declared store/pattern
- Events dispatch to the module's `handle_event/1` callback
- Return `:ok` to acknowledge, `{:error, reason}` to log a warning

**Options:**
- `store` — required
- `pattern` — required, glob pattern
- `max_queue_size` — optional, backpressure limit (default 1000)

### PubSub Bridge

Dust events broadcast to Phoenix.PubSub when configured:

```elixir
# config
config :my_app, MyApp.Dust, pubsub: MyApp.PubSub

# In LiveView
def mount(_params, _session, socket) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "dust:james/blog:posts.*")
  {:ok, socket}
end

def handle_info({:dust_event, event}, socket) do
  {:noreply, assign(socket, :latest_post, event.value)}
end
```

PubSub topic format: `"dust:{store}:{pattern}"`. Events arrive as `{:dust_event, event}` tuples.

### Test Harness

In test mode, Dust is a controllable fake. Seed it with state, trigger events, assert your code reacted correctly.

```elixir
# config/test.exs
config :my_app, MyApp.Dust, testing: :manual

# In tests
use Dust.Testing, dust: MyApp.Dust

test "page renders the latest post from Dust" do
  Dust.Testing.seed("james/blog", %{
    "posts.hello" => %{"title" => "Hello", "body" => "World"},
    "posts.goodbye" => %{"title" => "Goodbye", "body" => "Farewell"}
  })

  {:ok, view, _html} = live(conn, "/blog")
  assert has_element?(view, "h1", "Hello")
end

test "subscriber updates the cache when a post changes" do
  Dust.Testing.emit("james/blog", "posts.hello",
    op: :set,
    value: %{"title" => "Updated"}
  )

  assert MyApp.Cache.get("posts.hello").title == "Updated"
end

test "dashboard shows store status" do
  Dust.Testing.seed("james/blog", %{"config.x" => "val"})
  Dust.Testing.set_status("james/blog", :connected, store_seq: 42)

  {:ok, view, _html} = live(conn, "/dashboard")
  assert has_element?(view, ".sync-status", "connected")
end
```

**Three test primitives:**
- `seed(store, entries)` — populate the memory cache. `get`/`enum` return this data.
- `emit(store, path, event_attrs)` — fire an event through the subscriber pipeline as if the server sent it. Synchronous — all subscribers complete before `emit` returns.
- `set_status(store, status, opts)` — control what `Dust.status/1` returns.

In `:manual` mode, the SyncEngine uses a memory cache and never connects. `seed` writes to the cache. `emit` calls `SyncEngine.handle_server_event` synchronously. Application code calls the real Dust API — it just hits the seeded memory store.

## Crystal CLI

Standalone native binary. Speaks the Dust wire protocol directly. First non-Elixir client — validates the protocol spec is implementable from `protocol/spec/`.

### Commands

```
dust login                              # OAuth flow, stores credential
dust logout                             # Clear credentials
dust create <store>                     # Create a store
dust stores                             # List joined stores
dust status                             # Sync state per store

dust put <store> <path> <json>          # Set a value
dust get <store> <path>                 # Read a value
dust merge <store> <path> <json>        # Merge keys
dust delete <store> <path>              # Delete a path
dust enum <store> <pattern>             # Glob enumeration

dust increment <store> <path> [delta]   # Increment counter
dust add <store> <path> <member>        # Add to set
dust remove <store> <path> <member>     # Remove from set

dust put-file <store> <path> <file>     # Upload file
dust fetch-file <store> <path> <dest>   # Download file

dust watch <store> <pattern>            # Stream changes as JSON lines

dust log <store> [--path] [--op] [--since] [--limit]    # Audit log
dust rollback <store> <path> --to-seq <n>               # Path rollback
dust rollback <store> --to-seq <n>                      # Store rollback

dust token create --store <s> --read --write --name <n> # Create token
dust token list                                          # List tokens
dust token revoke <id>                                   # Revoke token

dust put <store> <path> --decimal "29.99"               # Typed values
dust put <store> <path> --datetime "2026-03-31T12:00:00Z"
```

### Architecture

```
cli/
  shard.yml
  src/
    dust.cr               # Entry point
    dust/
      cli.cr              # Command router
      commands/            # One file per command group
        auth.cr            # login, logout
        store.cr           # create, stores, status
        data.cr            # put, get, merge, delete, enum
        types.cr           # increment, add, remove
        files.cr           # put-file, fetch-file
        watch.cr           # watch (streaming)
        log.cr             # log, rollback
        token.cr           # token create, list, revoke
      client/
        connection.cr      # WebSocket + Phoenix Channel v2 protocol
        channel.cr         # Topic join/leave/push/receive
        heartbeat.cr       # 30s heartbeat timer
      cache/
        sqlite.cr          # SQLite cache (dust_cache table)
      config.cr            # ~/.config/dust/ credential + config management
      output.cr            # Formatting helpers (JSON, table, color)
```

### Wire Protocol

The CLI speaks Phoenix Channel v2 JSON over WebSocket:

- Connect: `ws://server/ws/sync/websocket?token=...&device_id=...&capver=1&vsn=2.0.0`
- Messages: `[join_ref, ref, topic, event, payload]` (JSON array)
- Join: `[ref, ref, "store:james/blog", "phx_join", {"last_store_seq": 0}]`
- Write: `[null, ref, "store:james/blog", "write", {"op": "set", "path": "...", ...}]`
- Receive events: `[join_ref, null, "store:james/blog", "event", {...}]`
- Heartbeat: `[null, ref, "phoenix", "heartbeat", {}]` every 30s

### Local Cache

SQLite database at `~/.local/share/dust/cache.db` (XDG base directory).

Same `dust_cache` table schema as the Ecto adapter:

```sql
CREATE TABLE dust_cache (
  store TEXT NOT NULL,
  path TEXT NOT NULL,
  value TEXT NOT NULL,
  type TEXT NOT NULL,
  seq INTEGER NOT NULL,
  PRIMARY KEY (store, path)
);
```

### Credentials

Stored in `~/.config/dust/credentials.json`:

```json
{
  "token": "dust_tok_...",
  "device_id": "dev_...",
  "server_url": "wss://api.dust.dev/ws/sync"
}
```

`dust login` performs OAuth, receives a token, writes credentials. `DUST_API_KEY` env var overrides for CI/scripts.

### Distribution

Crystal compiles to a single static binary — no runtime dependencies.

- **macOS:** Homebrew tap with precompiled bottles
- **Linux:** Precompiled binaries on GitHub releases
- **From source:** `crystal build src/dust.cr --release -o dust`

Homebrew formula lives in `cli/homebrew/dust.rb`.
