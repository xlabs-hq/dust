# Dust

A reactive global map. Create a store, write data, subscribe to changes — every connected client reacts.

Like Tailscale made networking disappear, Dust makes shared state disappear.

## What It Is

Dust is a hosted reactive map with native language SDKs. You create named stores, write structured data, and every connected client sees changes instantly. Subscribers register glob-pattern callbacks that fire when matching keys change. One write, every subscriber reacts.

## Quick Start

### CLI

```bash
# Install (from source — prebuilt binaries coming soon)
cd cli && crystal build src/dust.cr --release -o dust
cp dust /usr/local/bin/

# Authenticate
dust login

# Write and read
dust put james/blog posts.hello '{"title": "Hello", "body": "First post"}'
dust get james/blog posts.hello

# Subscribe to changes (streams JSON lines)
dust watch james/blog "posts.*"

# In another terminal — this triggers the watcher
dust merge james/blog posts.hello '{"updated": true}'
```

### Elixir SDK

```elixir
# mix.exs
{:dust, "~> 0.1"}
```

```elixir
# lib/my_app/dust.ex
defmodule MyApp.Dust do
  use Dust, otp_app: :my_app
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Dust,
  stores: ["james/blog"],
  repo: MyApp.Repo
```

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyApp.Dust,
  MyAppWeb.Endpoint
]
```

```elixir
# Write
MyApp.Dust.put("james/blog", "posts.hello", %{title: "Hello", body: "First post"})

# Read (instant, from local cache)
{:ok, post} = MyApp.Dust.get("james/blog", "posts.hello")

# Subscribe to changes
MyApp.Dust.on("james/blog", "posts.*", fn event ->
  IO.puts("#{event.path} changed!")
end)
```

Or run `mix dust.install` to generate the module, config, and migration automatically.

## Core Operations

### Set, Get, Delete

```elixir
Dust.put("james/blog", "posts.hello", %{title: "Hello", body: "World"})
{:ok, post} = Dust.get("james/blog", "posts.hello")
Dust.delete("james/blog", "posts.hello")
```

```bash
dust put james/blog posts.hello '{"title": "Hello"}'
dust get james/blog posts.hello
dust delete james/blog posts.hello
```

### Merge

Merge updates named child keys without replacing siblings:

```elixir
Dust.put("james/blog", "settings.theme", "light")
Dust.put("james/blog", "settings.locale", "en")
Dust.merge("james/blog", "settings", %{"theme" => "dark"})
# settings.theme is now "dark", settings.locale is still "en"
```

### Enum

List entries matching a glob pattern:

```elixir
entries = Dust.enum("james/blog", "posts.*")
# => [{"posts.hello", %{...}}, {"posts.goodbye", %{...}}]
```

```bash
dust enum james/blog "posts.*"
```

## Type System

### Counters

Counters solve concurrent increments. Two clients incrementing the same counter both succeed — the server sums the deltas.

```elixir
Dust.increment("james/blog", "stats.views")
Dust.increment("james/blog", "stats.views", 5)
{:ok, 6} = Dust.get("james/blog", "stats.views")
```

```bash
dust increment james/blog stats.views
dust increment james/blog stats.views 5
```

### Sets

Sets solve concurrent additions. Two clients adding different members both survive.

```elixir
Dust.add("james/blog", "post.tags", "elixir")
Dust.add("james/blog", "post.tags", "crystal")
Dust.remove("james/blog", "post.tags", "draft")
{:ok, ["elixir", "crystal"]} = Dust.get("james/blog", "post.tags")
```

```bash
dust add james/blog post.tags elixir
dust add james/blog post.tags crystal
dust remove james/blog post.tags draft
```

### Decimals and DateTimes

Typed values serialize losslessly:

```elixir
Dust.put("james/blog", "product.price", Decimal.new("29.99"))
Dust.put("james/blog", "post.published_at", ~U[2026-03-31 12:00:00Z])
```

```bash
dust put james/blog product.price --decimal "29.99"
dust put james/blog post.published_at --datetime "2026-03-31T12:00:00Z"
```

### Files

Files are stored as content-addressed blobs. The map stores a lightweight reference; content downloads on demand.

```elixir
Dust.put_file("james/blog", "posts.hello.image", "/path/to/photo.jpg")
{:ok, ref} = Dust.get("james/blog", "posts.hello.image")
ref.hash          # => "sha256:abc123..."
ref.size          # => 2_400_000
{:ok, bytes} = ref.fetch()
:ok = ref.download("/tmp/photo.jpg")
```

```bash
dust put-file james/blog posts.hello.image ./photo.jpg
dust fetch-file james/blog posts.hello.image ./output.jpg
```

## Reactive Subscriptions

### Glob Patterns

- `*` matches one path segment: `posts.*` matches `posts.hello` but not `posts.hello.title`
- `**` matches one or more segments: `posts.**` matches `posts.hello`, `posts.hello.title`, and deeper

### Elixir Callbacks

```elixir
Dust.on("james/blog", "posts.*", fn event ->
  # event.store, event.path, event.op, event.value
  # event.committed (true/false), event.source (:local/:server)
  rebuild_blog(event)
end)
```

### Declarative Subscribers

Define subscriber modules for automatic registration:

```elixir
defmodule MyApp.BlogSubscriber do
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

Register in config:

```elixir
config :my_app, MyApp.Dust,
  stores: ["james/blog"],
  subscribers: [MyApp.BlogSubscriber]
```

### CLI Watch

Stream changes as JSON lines:

```bash
dust watch james/blog "posts.*"
# {"store_seq":42,"op":"set","path":"posts.hello","value":{"title":"Hello"},...}
# {"store_seq":43,"op":"merge","path":"posts.hello","value":{"body":"Updated"},...}
```

### Phoenix PubSub

Dust events broadcast to Phoenix.PubSub for LiveView integration:

```elixir
# config
config :my_app, MyApp.Dust, pubsub: MyApp.PubSub

# In a LiveView
def mount(_params, _session, socket) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "dust:james/blog")
  {:ok, socket}
end

def handle_info({:dust_event, event}, socket) do
  {:noreply, assign(socket, :latest_post, event.value)}
end
```

## Audit Log and Rollback

Every write is logged. Query the audit trail by path, device, operation, or time range.

```elixir
Dust.Sync.Audit.query_ops(store_id, path: "posts.*", op: :set, limit: 50)
```

```bash
dust log james/blog --path "posts.*" --op set --limit 50
```

Rollback restores state to a previous point. It creates new forward operations — the audit trail is preserved.

```elixir
# Restore a single path
Dust.Sync.Rollback.rollback_path(store_id, "posts.hello", 40)

# Restore the entire store
Dust.Sync.Rollback.rollback_store(store_id, 40)
```

```bash
dust rollback james/blog posts.hello --to-seq 40
dust rollback james/blog --to-seq 40
```

## MCP Endpoint

The server exposes an MCP endpoint for AI agents. Any MCP client (Claude Code, Claude Desktop, Cursor) can read, write, and manage stores.

```json
{
  "mcpServers": {
    "dust": {
      "type": "url",
      "url": "http://localhost:7755/mcp",
      "headers": {
        "Authorization": "Bearer dust_tok_..."
      }
    }
  }
}
```

Available tools: `dust_get`, `dust_put`, `dust_merge`, `dust_delete`, `dust_enum`, `dust_increment`, `dust_add`, `dust_remove`, `dust_put_file`, `dust_fetch_file`, `dust_stores`, `dust_status`, `dust_log`, `dust_rollback`.

## Testing

In test mode, Dust runs against a memory cache with no server connection. Control state with three primitives:

```elixir
# config/test.exs
config :my_app, MyApp.Dust, testing: :manual
```

```elixir
# Seed the cache with known state
Dust.Testing.seed("james/blog", %{
  "posts.hello" => %{"title" => "Hello"},
  "posts.goodbye" => %{"title" => "Goodbye"}
})

# Your code reads from the seeded state
{:ok, post} = MyApp.Dust.get("james/blog", "posts.hello")
assert post["title"] == "Hello"
```

```elixir
# Simulate a server event to test your subscribers
Dust.Testing.emit("james/blog", "posts.hello",
  op: :set,
  value: %{"title" => "Updated"}
)
# All subscribers have run by the time emit returns
```

```elixir
# Control sync status for UI tests
Dust.Testing.set_status("james/blog", :connected, store_seq: 42)
```

## Architecture

### How It Works

1. **Write locally** — `put` writes to the local cache and returns immediately
2. **Sync in background** — the SDK sends the write to the server over WebSocket
3. **Server sequences** — the server assigns a canonical `store_seq` and broadcasts to all clients
4. **Clients converge** — every connected client applies the canonical event and fires matching callbacks

Reads never hit the network. Writes are optimistic. If the server is unreachable, reads still work from the cache.

### Conflict Resolution

The server processes writes one at a time per store. The canonical rule: later `store_seq` wins.

- **Unrelated paths** — both writes survive
- **Same path** — later write replaces the earlier one
- **Ancestor vs descendant** — `set` on a parent replaces the entire subtree
- **Merge** — updates named children, leaves siblings alone
- **Counters** — concurrent increments are summed
- **Sets** — concurrent adds both survive (add-wins semantics)

### Project Structure

```
dust/
  server/          # Phoenix app — the hosted sync service
  sdk/elixir/      # Elixir SDK + Phoenix integration
  protocol/
    spec/          # AsyncAPI definition + sync semantics doc
    elixir/        # Shared protocol types (MessagePack, paths, globs)
  cli/             # Crystal native CLI binary
```

## Server

### Running Locally

```bash
cd server
mix deps.get
mix ecto.create
mix ecto.migrate
mix phx.server
```

- **Dashboard:** http://localhost:7755 (Inertia/React)
- **Admin:** http://localhost:7766 (LiveView)
- **WebSocket:** ws://localhost:7755/ws/sync
- **MCP:** http://localhost:7755/mcp

### Environment Variables

```bash
DATABASE_URL=postgres://user:pass@localhost:5432/dust_dev
SECRET_KEY_BASE=...          # mix phx.gen.secret
WORKOS_API_KEY=sk_...        # WorkOS AuthKit (optional in dev)
WORKOS_CLIENT_ID=client_...
DUST_API_KEY=dust_tok_...    # For SDK/CLI connections
```

## Authentication

### Humans

`dust login` performs OAuth authentication. One-time setup.

### Deployments

Set `DUST_API_KEY=dust_tok_...` as an environment variable. The SDK reads it automatically.

### Scoped Tokens

Generate tokens with per-store, per-permission scope from the web dashboard at `/:org/tokens`.

## License

MIT
