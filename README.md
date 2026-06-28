# Dust

A reactive global map. Create a store, write data, subscribe to changes — every connected client reacts.

Like Tailscale made networking disappear, Dust makes shared state disappear.

## What It Is

Dust is a hosted reactive map with native language SDKs. You create named stores, write structured data, and every connected client sees changes instantly. Subscribers register glob-pattern callbacks that fire when matching keys change. One write, every subscriber reacts.

## Which Package Should I Use?

Use **`dust`** for hot-path application reads, realtime subscriptions, and
offline-tolerant services. It runs a supervised sync engine and reads from a
local cache in your app's database.

Use **`dust_ecto`** when you want an Ecto-shaped API (`Schema`, changesets,
and a small Repo facade) over Dust records. For production hot paths, run the
`dust` supervisor and configure `dust_ecto` to use SDK mode; its HTTP mode is
best for scripts, release tasks, and low-frequency stateless calls.

## Quick Start

### CLI

```bash
# Install (from source — prebuilt binaries coming soon)
cd cli && crystal build src/dust.cr --release -o dust
cp dust /usr/local/bin/

# Authenticate
dust login

# Write and read
dust put james/blog posts/hello '{"title": "Hello", "body": "First post"}'
dust get james/blog posts/hello

# Subscribe to changes (streams JSON lines)
dust watch james/blog "posts/*"

# In another terminal — this triggers the watcher
dust merge james/blog posts/hello '{"updated": true}'
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
MyApp.Dust.put("james/blog", "posts/hello", %{title: "Hello", body: "First post"})

# Read (instant, from local cache)
{:ok, post} = MyApp.Dust.get("james/blog", "posts/hello")

# Subscribe to changes
MyApp.Dust.on("james/blog", "posts/*", fn event ->
  IO.puts("#{event.path} changed!")
end)
```

Or run `mix dust.install` to generate the module, config, and migration automatically.

### TypeScript SDK

```bash
npm install @dust-sync/sdk
```

```typescript
import { Dust } from "@dust-sync/sdk"

const dust = new Dust({
  url: "wss://your-host.com/ws/sync",
  token: "dust_tok_...",
})

// Write
await dust.put("james/blog", "posts/hello", { title: "Hello", body: "First post" })

// Read (instant, from local cache)
const post = await dust.get("james/blog", "posts/hello")

// Subscribe to changes
const unsub = dust.on("james/blog", "posts/*", (event) => {
  console.log(`${event.path} changed!`)
})
```

## Core Operations

### Set, Get, Delete

```elixir
Dust.put("james/blog", "posts/hello", %{title: "Hello", body: "World"})
{:ok, post} = Dust.get("james/blog", "posts/hello")
Dust.delete("james/blog", "posts/hello")
```

```bash
dust put james/blog posts/hello '{"title": "Hello"}'
dust get james/blog posts/hello
dust delete james/blog posts/hello
```

### Merge

Merge updates named child keys without replacing siblings:

```elixir
Dust.put("james/blog", "settings/theme", "light")
Dust.put("james/blog", "settings/locale", "en")
Dust.merge("james/blog", "settings", %{"theme" => "dark"})
# settings/theme is now "dark", settings/locale is still "en"
```

### Enum

List entries matching a glob pattern:

```elixir
entries = Dust.enum("james/blog", "posts/*")
# => [{"posts/hello", %{...}}, {"posts/goodbye", %{...}}]
```

With pagination and ordering:

```elixir
page = Dust.enum("james/blog", "posts/**", limit: 20, order: :desc)
# => %Dust.Page{items: [...], next_cursor: "..."}

# Cursor-based pagination
next_page = Dust.enum("james/blog", "posts/**", limit: 20, after: page.next_cursor)

# Select modes: :entries (default), :keys, :prefixes
keys = Dust.enum("james/blog", "posts/**", select: :keys)
```

```bash
dust enum james/blog "posts/**" --limit 20 --order desc
dust enum james/blog "posts/**" --select keys
```

### Entry

Get the full entry (path, value, type, revision, and local sync timestamp)
instead of just the value:

```elixir
{:ok, entry} = Dust.entry("james/blog", "posts/hello")
# => %Dust.Entry{
#      path: "posts/hello",
#      value: %{...},
#      type: "map",
#      revision: 42,
#      synced_at: 1_787_000_000_000
#    }
```

`synced_at` is the local wall-clock time, in Unix epoch milliseconds, when
this mirror last wrote the cache row from a sync event. Use it to reason about
local mirror freshness. It is not server commit time, and subtree-assembled
entries may report `nil`.

### GetMany

Batch-read up to 1000 paths in one call:

```elixir
values = Dust.get_many("james/blog", ["posts/hello", "posts/goodbye", "settings/theme"])
# => %{"posts/hello" => %{...}, "settings/theme" => "dark"}
```

### Range

Read entries in a lexicographic range `[from, to)`:

```elixir
page = Dust.range("james/blog", "metrics/2026-04-01", "metrics/2026-04-30", limit: 100)
# => %Dust.Page{items: [...], next_cursor: "..."}
```

```bash
dust range james/blog metrics/2026-04-01 metrics/2026-04-30 --limit 100
```

### Compare-and-Swap

Conditional writes using optimistic concurrency. Pass the expected revision — the write fails with `:conflict` if another write landed first:

```elixir
{:ok, entry} = Dust.entry("james/blog", "posts/hello")
case Dust.put("james/blog", "posts/hello", updated_post, if_match: entry.revision) do
  :ok -> :saved
  {:error, :conflict} -> :retry
end
```

```bash
dust put james/blog posts/hello '{"title":"Updated"}' --if-match 42
# Exit code 1 on conflict
```

## Type System

### Counters

Counters solve concurrent increments. Two clients incrementing the same counter both succeed — the server sums the deltas.

```elixir
Dust.increment("james/blog", "stats/views")
Dust.increment("james/blog", "stats/views", 5)
{:ok, 6} = Dust.get("james/blog", "stats/views")
```

```bash
dust increment james/blog stats/views
dust increment james/blog stats/views 5
```

### Sets

Sets solve concurrent additions. Two clients adding different members both survive.

```elixir
Dust.add("james/blog", "post/tags", "elixir")
Dust.add("james/blog", "post/tags", "crystal")
Dust.remove("james/blog", "post/tags", "draft")
{:ok, ["elixir", "crystal"]} = Dust.get("james/blog", "post/tags")
```

```bash
dust add james/blog post/tags elixir
dust add james/blog post/tags crystal
dust remove james/blog post/tags draft
```

### Decimals and DateTimes

Typed values serialize losslessly:

```elixir
Dust.put("james/blog", "product/price", Decimal.new("29.99"))
Dust.put("james/blog", "post/published_at", ~U[2026-03-31 12:00:00Z])
```

```bash
dust put james/blog product/price --decimal "29.99"
dust put james/blog post/published_at --datetime "2026-03-31T12:00:00Z"
```

### Files

Files are stored as content-addressed blobs. The map stores a lightweight reference; content downloads on demand.

```elixir
Dust.put_file("james/blog", "posts/hello/image", "/path/to/photo.jpg")
{:ok, ref} = Dust.get("james/blog", "posts/hello/image")
ref.hash          # => "sha256:abc123..."
ref.size          # => 2_400_000
{:ok, bytes} = ref.fetch()
:ok = ref.download("/tmp/photo.jpg")
```

```bash
dust put-file james/blog posts/hello/image ./photo.jpg
dust fetch-file james/blog posts/hello/image ./output.jpg
```

## Reactive Subscriptions

### Glob Patterns

- `*` matches one path segment: `posts/*` matches `posts/hello` but not `posts/hello/title`
- `**` matches one or more segments: `posts/**` matches `posts/hello`, `posts/hello/title`, and deeper

### Elixir Callbacks

```elixir
Dust.on("james/blog", "posts/*", fn event ->
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
    pattern: "posts/*"

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

### Watch with Bootstrap

`watch` combines subscription with an initial snapshot — it delivers all matching cached entries as `present` events before any live events. This avoids the "subscribe then backfill" race window:

```elixir
# Elixir — watch/4 is an alias for on/4
Dust.on("james/blog", "posts/*", fn event ->
  # First batch: event.op == :present for cached entries
  # Then live: :set, :merge, :delete, etc.
end)
```

```typescript
// TypeScript — watch() delivers present events then live events
const unsub = await dust.watch("org/store", "posts/*", (event) => {
  if (event.op === "present") {
    // Bootstrap: currently cached entry
  } else {
    // Live update
  }
}, { limit: 100, order: "desc" })
```

### CLI Watch

Stream changes as JSON lines:

```bash
dust watch james/blog "posts/*"
# {"store_seq":42,"op":"set","path":"posts/hello","value":{"title":"Hello"},...}
# {"store_seq":43,"op":"merge","path":"posts/hello","value":{"body":"Updated"},...}

# Include currently cached entries before streaming live events
dust watch james/blog "posts/*" --include-current
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
Dust.Sync.Audit.query_ops(store_id, path: "posts/*", op: :set, limit: 50)
```

```bash
dust log james/blog --path "posts/*" --op set --limit 50
```

Rollback restores state to a previous point. It creates new forward operations — the audit trail is preserved.

```elixir
# Restore a single path
Dust.Sync.Rollback.rollback_path(store_id, "posts/hello", 40)

# Restore the entire store
Dust.Sync.Rollback.rollback_store(store_id, 40)
```

```bash
dust rollback james/blog posts/hello --to-seq 40
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
  "posts/hello" => %{"title" => "Hello"},
  "posts/goodbye" => %{"title" => "Goodbye"}
})

# Your code reads from the seeded state
{:ok, post} = MyApp.Dust.get("james/blog", "posts/hello")
assert post["title"] == "Hello"
```

```elixir
# Simulate a server event to test your subscribers
Dust.Testing.emit("james/blog", "posts/hello",
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
  sdk/
    elixir/        # Elixir SDK + Phoenix integration
    typescript/    # TypeScript/Node.js SDK (@dust-sync/sdk)
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

Generate tokens from the web dashboard at `/:org/tokens` or with `dust token create`.
Token authority has two independent dimensions:

- **Scopes** describe what the token can do. Common scopes are `entries:read`,
  `entries:write`, `files:read`, `files:write`, `webhooks:read`,
  `webhooks:write`, `audit:read`, `stores:read`, `stores:clone`,
  `tokens:read`, and `tokens:write`.
- **Store access** describes where the token can act: all stores in the account
  or a selected set of stores.

SDK reads require `entries:read`. Writes, leases, rollback, and
`singleFlight`/`single_flight` require `entries:write`; a read-only token can
connect, join, and read, but write-like operations fail with a structured
`missing_scope` error.

After a WebSocket join, the server returns capability metadata:

```json
{
  "permissions": { "read": true, "write": false },
  "scopes": ["entries:read"],
  "store_access": { "mode": "selected", "store_ids": ["..."] }
}
```

The SDKs expose this from `status(store)` so applications can fail fast or
show a clear diagnostic before attempting a write.

### MCP OAuth

MCP clients (Claude Desktop, Cursor, ChatGPT) authenticate via OAuth 2.1 with Dynamic Client Registration. Point your MCP client at `https://<host>/mcp` and it discovers the flow automatically.

Discovery endpoints:

- `GET /.well-known/oauth-authorization-server` — server metadata
- `GET /.well-known/oauth-protected-resource` — resource metadata
- `POST /register` — Dynamic Client Registration
- `GET /oauth/authorize` → `GET /oauth/callback` — authorization code flow
- `POST /oauth/token` — exchange code for access token (30-day sliding expiry)

## License

MIT
