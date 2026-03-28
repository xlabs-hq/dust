# Dust: A Reactive Global Map

## One-Sentence Pitch

Create a store, write data, subscribe to changes — every connected client reacts. The Dropbox of application state.

## What It Is

Dust is a hosted reactive map with native language SDKs. You create named stores, write structured data, and every connected client sees changes instantly. Subscribers register glob-pattern callbacks that fire when matching keys change. One write, every subscriber reacts.

Install the daemon, drop in an API key, and your software has a shared reactive data layer across every device and deployment. No infrastructure to manage, no initialization ceremony, no vendor ecosystem to buy into. Like Tailscale made networking disappear, Dust makes shared state disappear.

## MVP Biases

- **Fast local UX** — reads and writes stay local-first through the daemon.
- **Server-authoritative ordering** — the server assigns one canonical sequence per store.
- **Predictable conflict rules** — whole-subtree edits beat narrower concurrent edits.
- **Live subscriptions, not durable jobs** — callbacks are for reactive apps, not background work queues.
- **Simple recovery model** — if a subscriber falls behind or restarts, it replays state with `enum` and resumes live updates with `on`.

## Core Properties

- **Named stores** with slash-separated names (`james/blog`, `acme/config`). Explicit creation and membership.
- **Structured values** — nested maps/hashes, up to 64KB per write payload. Rich type system including decimals, datetimes, counters, sets, and files (files have no size limit).
- **Reactive subscriptions** — glob-pattern matching on key paths (`posts.*`, `translations.**`). Callbacks fire locally with metadata about whether an event is optimistic or committed.
- **Server-managed ordering and conflict resolution** — every accepted write is placed into a single per-store log. Users do not reason about vector clocks or peer-to-peer merge state.
- **Cache-first reads** — reads come from the local cache (your app's database), not the network. Writes queue locally and sync in the background. If the server is unreachable, reads still work.
- **Multi-language SDKs** — Elixir, Ruby, Python, TypeScript. Each connects directly to the Dust server and caches locally in your app's existing database. Idiomatic in every language.
- **API key auth** — `dust login` for humans, `DUST_API_KEY` env var for deployments. Scoped tokens for least-privilege access to specific stores.
- **Capability versioning** — Tailscale-style capver integer for protocol evolution without flag days.
- **Audit log and rollback** — the op log is the audit trail. Rollback to any point within the retention window.

## What Dust Is Not

- **Not a database** — no queries, no indexes, no transactions. Path structure is your schema.
- **Not a general file store** — files are a first-class type, but Dust is optimized for structured data (values up to 64KB). Use files for content that belongs with your data (images, documents), not as a CDN or bulk storage.
- **Not an ecosystem** — no cloud functions, no hosting, no auth-as-a-service. Just the map.
- **Not a message queue** — callbacks fire on state changes, not ephemeral events.

## Who It's For

Developers who need shared reactive state without the ceremony. Your blog publishes a post and every deployment picks it up. Your translation pipeline writes output once and every site reacts. Your config changes and every running instance knows immediately.

## Architecture

### 1. Dust Server

The hosted central service. Receives writes, applies conflict resolution, assigns canonical ordering, stores current state, and fans out updates to all connected clients. Maintains the operation log for ordered catch-up. Exposes both a WebSocket endpoint (for real-time sync) and a REST/MCP endpoint. Manages authentication, store membership, and token scoping. Sees all data in plaintext — this is what enables smart merging.

The server processes writes one at a time per store. Each accepted write gets a monotonically increasing `store_seq`. This is the simplest correctness model; stores are independent, so throughput scales with the number of stores.

### 2. Language SDKs

Each SDK connects directly to the Dust server over WebSocket. The SDK manages the connection, handles reconnect and catch-up sync, applies optimistic local state, reconciles server responses, and dispatches incoming changes to registered callbacks.

Local state is persisted through a **cache adapter** — a pluggable storage backend that keeps a copy of store data in whatever database the app already uses. On boot, the SDK reads from the cache (instant, no network), then connects to the server and catches up from the cached `last_store_seq`. If the server is unreachable, reads still work from the cache.

### 3. Dust CLI / Daemon

The CLI is a standalone client that uses SQLite as its cache adapter. It is not architecturally special — it's the same sync engine as the SDKs, packaged as a command-line tool. `brew install dust && dust login` — that's the setup.

The daemon mode (`dust daemon`) keeps a persistent background connection and SQLite cache, useful for laptop users who want offline support or developers who prefer the CLI workflow. Applications do not depend on the daemon.

### Cache Adapters

Every Dust client (SDK or CLI) uses a cache adapter for local persistence. The adapter interface is small:

- `read(store, path)` — read a cached value
- `read_all(store, pattern)` — read all cached values matching a glob pattern
- `write(store, path, value, type, seq)` — write a cached value
- `write_batch(store, entries)` — batch write
- `delete(store, path)` — delete a cached value
- `last_seq(store)` — last synced `store_seq`

**Built-in adapters:**

| Adapter | Used by | Storage |
|---------|---------|---------|
| Ecto (Postgres/MySQL/SQLite) | Elixir apps | App database |
| ActiveRecord | Ruby apps | App database |
| SQLAlchemy | Python apps | App database |
| Prisma / Knex | TypeScript apps | App database |
| SQLite | CLI / Daemon | Local file |
| Memory | Scripts, Lambda, tests | In-process |

**Custom adapters:** implement the six-method interface to use any backend (DynamoDB, Redis, etc.).

The SDK provides a migration that creates a single cache table:

```sql
CREATE TABLE dust_cache (
  store   TEXT NOT NULL,
  path    TEXT NOT NULL,
  value   BYTEA NOT NULL,
  type    TEXT NOT NULL,
  seq     BIGINT NOT NULL,
  PRIMARY KEY (store, path)
);
```

Standard SQL, no extensions. The migration runs on install or can be added to your app's migration pipeline.

### Client Modes

| Mode | Cache | Connection | Best for |
|------|-------|-----------|----------|
| **DB-cached** | App database | Direct to server | Web apps, services, Docker — the default |
| **Daemon** | SQLite | Background process | Laptops, CLI, offline use |
| **Stateless** | In-memory only | Direct to server | Scripts, Lambda, one-off jobs |

## Data Model

A store is a tree of maps and typed values. Paths address nodes in that tree.

### Operations

- `set(path, value)` replaces the value at `path`. If `value` is a map, it replaces the subtree rooted at `path`.
- `delete(path)` removes the value at `path` and everything below it.
- `merge(path, map)` updates only the named child keys under `path` and leaves unmentioned children alone.
- `get(path)` returns the materialized value at that node. Reading a map path returns the assembled subtree.
- `enum(pattern)` returns all key-value pairs matching a glob pattern from the local copy.
- `increment(path, delta)` atomically adds `delta` to a counter at `path`.
- `add(path, member)` adds a member to a set at `path`.
- `remove(path, member)` removes a member from a set at `path`.
- `put_file(path, source)` uploads a file and stores a content-addressed reference at `path`.

### Type System

Values in the map are typed. The server uses the type to determine conflict resolution behavior.

| Type | Description | Conflict behavior | Wire representation |
|------|-------------|-------------------|---------------------|
| **String** | UTF-8 text | LWW | MessagePack string |
| **Integer** | Arbitrary precision integer | LWW | MessagePack integer |
| **Float** | IEEE 754 double | LWW | MessagePack float |
| **Boolean** | true/false | LWW | MessagePack boolean |
| **Null** | Absence of value | LWW | MessagePack nil |
| **Map** | Nested key-value structure | Structural merge | MessagePack map |
| **Decimal** | Arbitrary precision decimal | LWW | MessagePack ext type (string-encoded) |
| **DateTime** | Timestamp with timezone | LWW | MessagePack ext type (RFC 3339) |
| **Counter** | Numeric counter | Additive merge | MessagePack ext type (delta on wire, materialized value on read) |
| **Set** | Unordered collection of unique values | Union on add, explicit remove | MessagePack ext type (operation on wire, materialized set on read) |
| **File** | Content-addressed blob reference | LWW on reference | MessagePack ext type (metadata map) |

**Design principle:** `get` always returns the natural value. A counter reads as a number. A set reads as a native set. A file reads as a file reference with metadata and a `fetch` method. The type system is invisible until you need it.

### Counter

Counters solve the problem where two clients both increment the same value concurrently. With LWW, one increment is lost. With additive merge, the server sums the deltas.

The wire format is a delta: `increment("stats.views", 3)` sends `+3`. The server applies deltas to the current value. On read, `get("stats.views")` returns the materialized number (e.g., `42`), not a counter object.

### Set

Sets solve the problem where two clients both add different members concurrently. With LWW, one addition is lost. With union merge, both survive.

Operations: `add(path, member)` and `remove(path, member)`. Concurrent adds of different members both survive. Concurrent add and remove of the same member: add wins (add-wins semantics — safer default, never silently loses data).

On read, `get` returns the language-native set type: `MapSet` in Elixir, `Set` in Ruby/Python/TypeScript, `dust.Set` wrapper in Go.

### File

Files are stored as content-addressed blobs in server-side object storage, separate from the map data plane. The map stores a lightweight reference:

```
%{
  _type: :file,
  hash: "sha256:abc123...",
  size: 2_400_000,
  content_type: "image/jpeg",
  filename: "photo.jpg",
  uploaded_at: "2026-03-26T12:00:00Z"
}
```

`put_file` uploads the blob first, then writes the reference to the map. This is the one write operation that blocks on network — the blob must land in storage before the reference is written, to prevent dangling references.

`get` on a file path returns a file reference object with metadata and a `fetch` method. The reference is instant (local). Fetching the content is an explicit network call:

```elixir
ref = Dust.get("james/blog", "posts.hello.image")
ref.size          # => 2_400_000 (instant, from metadata)
ref.content_type  # => "image/jpeg" (instant)
ref.hash          # => "sha256:abc123..." (instant)
bytes = ref.fetch()           # network download
ref.download("/tmp/photo.jpg") # stream to disk
```

**Content addressing** means identical files are stored once. Two stores uploading the same image share the underlying blob. Garbage collection runs during log compaction — when a file reference is overwritten or deleted and no other reference points to that hash, the blob is removed.

**Callbacks** receive the file reference, not the blob content. The handler decides whether to download:

```elixir
Dust.on("james/blog", "posts.**.image", fn event ->
  ref = event.value
  path = "/images/#{ref.hash}"
  unless File.exists?(path), do: ref.download(path)
end)
```

### Billing

For limits and billing, a **key** means a materialized leaf path in the current store state. Interior map nodes are not billed separately. Files are billed as one key each (the reference), plus storage quota for blob content.

## Writing a Value

### User-visible behavior

1. SDK sends `put`, `merge`, or `delete` to the daemon with a client-generated `client_op_id`.
2. The daemon applies the change to local state immediately.
3. The SDK call returns immediately once the local write succeeds.
4. Matching local subscriptions fire immediately with `committed: false` and `source: :local`.
5. The daemon sends the write to the server in the background.
6. The server validates the write, assigns a canonical `store_seq`, applies it to the authoritative store state, and echoes the canonical event to every connected daemon, including the origin.
7. The origin daemon reconciles the echoed event with its optimistic local write.

### Origin reconciliation

- If the server accepted the write as-is, the origin daemon marks the local write committed and does **not** fire callbacks again.
- If the server canonicalized the result differently, the daemon applies the canonical state and fires a second callback with `committed: true`, `source: :server`, and `correction_for: client_op_id`.
- If the server rejected the write, the daemon rolls back the optimistic local change and fires a correction callback with `committed: false`, `source: :server`, and an error.

This keeps local UX snappy without pretending optimistic writes are already durable.

### Reading a value

1. SDK calls `Dust.get(store, path)` — daemon returns from local store.
2. Pure local read. Sub-millisecond.

## Conflict Resolution

The server processes writes one at a time into the authoritative store state. The canonical rule is: later `store_seq` wins.

### Path scope rules

- **Unrelated paths**: if neither path is an ancestor of the other, both writes survive.
- **Same path**: the later committed write replaces the earlier one.
- **Ancestor vs descendant**: a `set` or `delete` on an ancestor path replaces the whole subtree rooted there. It wins over earlier concurrent descendant writes.
- **Later descendant after ancestor**: if the descendant write is committed later, it recreates part of the subtree under that path.
- **`merge(path, map)`**: merge only touches the named child keys under `path`. Untouched siblings survive.
- **`merge` vs `set` on the same path**: the later committed write wins for the whole path.

### Type-specific merge rules

- **Counter**: concurrent increments are summed. `increment(path, 3)` and `increment(path, 5)` both committed → value increases by 8. A `set` on a counter path resets it (LWW).
- **Set**: concurrent adds both survive (union). Concurrent add and remove of the same member → add wins. A `set` on a set path replaces the entire set (LWW).
- **File**: LWW on the reference. If two clients upload different files to the same path, the later reference wins. Both blobs remain in storage until GC determines one is unreferenced.
- **All other types**: LWW.

### Examples

- `delete("posts")` committed after `set("posts.hello", ...)` removes `posts.hello`.
- `set("settings", %{theme: "dark"})` committed after `merge("settings", %{locale: "en"})` leaves only `%{theme: "dark"}`.
- `merge("settings", %{theme: "dark"})` committed after `set("settings", %{locale: "en"})` yields `%{locale: "en", theme: "dark"}`.
- `increment("stats.views", 1)` from two devices concurrently → views increases by 2.
- `add("post.tags", "elixir")` and `add("post.tags", "rust")` concurrently → both tags survive.

These rules favor predictability over cleverness.

## Wire Protocol

### Canonical Event Shape

Every accepted server event:

```
{store, store_seq, op, path, value?, device_id, client_op_id}
```

- `store_seq` — monotonically increasing integer assigned by the server per store.
- `client_op_id` — echoed back to let the origin reconcile optimistic local state.
- `device_id` — identifies who submitted the write.

The daemon may also emit **local-only optimistic events** to SDK subscribers before the server echo arrives:

```
{store, op, path, value?, device_id, client_op_id, committed: false, source: :local}
```

Optimistic events do not have a `store_seq` yet.

### Catch-Up Sync

Each daemon tracks `last_store_seq` per store. On reconnect:

1. The daemon sends `last_store_seq`.
2. The server responds with all canonical events where `store_seq > last_store_seq`.
3. The daemon applies them in order and advances `last_store_seq`.

The server may compact old log entries into snapshots:

- A snapshot is the materialized store state at `snapshot_seq`.
- If a client reconnects behind the snapshot point, the server sends the snapshot plus the tail of the log after `snapshot_seq`.

### Transport

- Client to Server: WebSocket, persistent connection. MessagePack on the wire.
- All clients (SDKs, CLI, daemon) use the same WebSocket protocol.

### Capability Versioning

A single integer, incremented when the protocol changes. Client sends its capver on connection. Server responds with the range it supports.

```
Client hello: {capver: 1, device_id: "abc", token: "dust_..."}
Server hello: {capver_min: 1, capver_max: 1, your_capver: 1}
```

If the client's capver falls outside the server's range, the connection is rejected with a "please upgrade" message.

The MVP ships with `capver = 1`. All operations (`set`, `delete`, `merge`, `increment`, `add`, `remove`, `put_file`), subscriptions, `enum`, and catch-up sync are included in capver 1. The MVP does not attempt fan-out downgrades or semantic translation between versions.

## Callback Semantics

### Delivery Model

Subscriptions are **live application callbacks**. They are not a durable queue and they are not replayed across process restarts.

Recommended application pattern:

1. Call `enum` on boot to build current state.
2. Register `on` to receive live changes going forward.
3. If the process restarts, repeat the pattern.

This keeps the daemon and SDKs small while giving applications a clear recovery story.

### Subscription Patterns

Glob-style matching on dotted paths:

- `*` matches one path segment: `posts.*` matches `posts.hello` but not `posts.hello.title`.
- `**` matches any depth: `posts.**` matches `posts.hello`, `posts.hello.title`, and `posts.archive.2024.jan`.
- Exact paths match exactly: `config.timeout` matches only `config.timeout`.

### Ordering

- Canonical server events are delivered to each subscription in ascending `store_seq` order.
- Optimistic local events may arrive before their corresponding committed server event.
- If the server accepts the write unchanged, the optimistic event is the only callback the origin sees.
- If the server corrects or rejects the write, the origin sees a second callback describing that correction.

### Backpressure

Each subscription has a bounded in-memory queue.

- Default queue size: `1_000` events.
- If a subscription falls behind, the daemon drops that subscription and marks it `resync_required`.
- Store sync continues normally; one slow subscriber does not stall the whole daemon.

The SDK surfaces `resync_required` as an error so the application can call `enum` and re-subscribe.

### Event Shape

SDK callbacks receive an event:

```
%{
  store: "james/blog",
  path: "posts.hello",
  op: :set | :delete | :merge | :increment | :add | :remove | :put_file,
  value: ...,
  device_id: "dev_123",
  client_op_id: "op_456",
  store_seq: 42 | nil,
  committed: true | false,
  source: :local | :server,
  correction_for: "op_456" | nil,
  error: nil | %{code: ..., message: ...}
}
```

Most events are simple:

- Local optimistic write: `committed: false`, `source: :local`, `store_seq: nil`
- Normal committed remote change: `committed: true`, `source: :server`, `store_seq: 42`
- Correction or rejection: `source: :server`, with either `committed: true` or an `error`

## CLI

The CLI is a full-featured client, not a subset. Every operation available to SDKs is available from the command line. This makes scripting, debugging, and exploring stores a first-class experience.

### Setup

```
$ brew install dust                # or cargo install, apt, etc.
$ dust login                       # OAuth/magic link, one-time
$ dust create james/blog           # create a store
$ dust token create --store james/blog --read --name blog-deploy
# → dust_tok_abc123...
$ dust stores                      # list joined stores
$ dust status                      # daemon health, sync state
```

### Basic operations

```
$ dust put james/blog posts.hello '{"title":"Hello","body":"..."}'
$ dust get james/blog posts.hello
$ dust merge james/blog settings '{"theme":"dark"}'
$ dust delete james/blog posts.old-draft
$ dust ls james/blog posts         # list keys under a path
$ dust enum james/blog "posts.*"   # glob-pattern enumeration
```

### Counters

```
$ dust increment james/blog stats.views        # +1 (default)
$ dust increment james/blog stats.views 5      # +5
$ dust increment james/blog stats.views -- -1  # -1 (decrement)
$ dust get james/blog stats.views              # => 42
```

### Sets

```
$ dust add james/blog post.tags elixir
$ dust add james/blog post.tags rust
$ dust remove james/blog post.tags draft
$ dust get james/blog post.tags                # => ["elixir", "rust"]
```

### Files

```
$ dust put-file james/blog posts.hello.image ./photo.jpg
$ dust get james/blog posts.hello.image        # shows metadata (hash, size, type)
$ dust fetch-file james/blog posts.hello.image ./output.jpg  # download content
```

### Subscriptions

```
$ dust watch james/blog "posts.*"              # stream changes to stdout as JSON lines
$ dust watch james/blog "posts.**" --op set    # filter by operation type
```

`watch` outputs one JSON object per line per event — designed for piping into `jq`, scripts, or other tools. It runs until interrupted.

### Decimals and DateTimes

```
$ dust put james/blog product.price --decimal "29.99"
$ dust put james/blog post.published_at --datetime "2026-03-26T12:00:00Z"
```

Type flags (`--decimal`, `--datetime`) tell the CLI to store a typed value rather than a plain string. Without the flag, `"29.99"` would be stored as a string.

### Audit log

```
$ dust log james/blog                              # recent ops
$ dust log james/blog --path "posts.*"             # filter by path
$ dust log james/blog --device dev_abc             # filter by device
$ dust log james/blog --op set                     # filter by operation type
$ dust log james/blog --since 2026-03-25           # filter by time
$ dust log james/blog --limit 100                  # limit results
```

### Rollback

```
$ dust rollback james/blog posts.hello --to-seq 40
# => Rolled back posts.hello to store_seq 40 (new store_seq: 87)

$ dust rollback james/blog --to-seq 40
# => ⚠ This will reset the entire store to store_seq 40.
# => 46 keys will be modified, 12 keys will be deleted.
# => Continue? [y/N]
```

## SDK API

### Elixir

```elixir
# Supervision tree — cache in your app's database
{Dust, stores: ["james/blog"], cache: {Dust.Cache.Ecto, repo: MyApp.Repo}}

# Read/write
Dust.get("james/blog", "posts.hello")
Dust.put("james/blog", "posts.hello", %{title: "Hello", body: "..."})
Dust.merge("james/blog", "settings", %{theme: "dark"})
Dust.delete("james/blog", "posts.old-draft")

# Counters
Dust.increment("james/blog", "stats.views")
Dust.increment("james/blog", "stats.views", 5)

# Sets
Dust.add("james/blog", "post.tags", "elixir")
Dust.remove("james/blog", "post.tags", "draft")

# Files
Dust.put_file("james/blog", "posts.hello.image", "/path/to/photo.jpg")
ref = Dust.get("james/blog", "posts.hello.image")
ref.hash          # => "sha256:abc123..."
bytes = ref.fetch()

# Typed values
Dust.put("james/blog", "product.price", Decimal.new("29.99"))
Dust.put("james/blog", "post.published_at", DateTime.utc_now())

# Subscribe
Dust.on("james/blog", "posts.*", fn event ->
  BlogEngine.rebuild(event)
end)

# Enumerate
Dust.enum("james/blog", "posts.*")
|> Enum.map(fn {path, post} -> post.title end)
|> Enum.sort()

# Audit log
Dust.log("james/blog", path: "posts.*", limit: 50)

# Rollback
Dust.rollback("james/blog", "posts.hello", to_seq: 40)
Dust.rollback("james/blog", to_seq: 40)  # whole store
```

### Ruby

```ruby
dust = Dust.new("james/blog", cache: :activerecord)

# Read/write
dust.get("posts.hello")
dust.put("posts.hello", {title: "Hello", body: "..."})
dust.merge("settings", {theme: "dark"})
dust.delete("posts.old-draft")

# Counters
dust.increment("stats.views")
dust.increment("stats.views", 5)

# Sets
dust.add("post.tags", "elixir")
dust.remove("post.tags", "draft")

# Files
dust.put_file("posts.hello.image", "/path/to/photo.jpg")
ref = dust.get("posts.hello.image")
ref.fetch  # => bytes

# Typed values
dust.put("product.price", BigDecimal("29.99"))
dust.put("post.published_at", Time.now)

# Subscribe
dust.on("posts.*") { |event| rebuild_index(event) }

# Enumerate
dust.enum("posts.*").map { |path, post| post["title"] }.sort

# Audit log
dust.log(path: "posts.*", limit: 50)

# Rollback
dust.rollback("posts.hello", to_seq: 40)
dust.rollback(to_seq: 40)  # whole store
```

### Python

```python
dust = Dust("james/blog", cache=engine)  # SQLAlchemy engine

# Read/write
dust.get("posts.hello")
dust.put("posts.hello", {"title": "Hello", "body": "..."})
dust.merge("settings", {"theme": "dark"})
dust.delete("posts.old-draft")

# Counters
dust.increment("stats.views")
dust.increment("stats.views", 5)

# Sets
dust.add("post.tags", "elixir")
dust.remove("post.tags", "draft")

# Files
dust.put_file("posts.hello.image", "/path/to/photo.jpg")
ref = dust.get("posts.hello.image")
data = ref.fetch()

# Typed values
from decimal import Decimal
from datetime import datetime, timezone
dust.put("product.price", Decimal("29.99"))
dust.put("post.published_at", datetime.now(timezone.utc))

# Subscribe
@dust.on("posts.*")
def handle_post(event):
    rebuild_index(event)

# Enumerate
titles = [post["title"] for path, post in dust.enum("posts.*")]

# Audit log
dust.log(path="posts.*", limit=50)

# Rollback
dust.rollback("posts.hello", to_seq=40)
dust.rollback(to_seq=40)  # whole store
```

### TypeScript

```typescript
const dust = new Dust("james/blog", { cache: pool });  // Knex/Prisma pool

// Read/write
await dust.get("posts.hello");
await dust.put("posts.hello", { title: "Hello", body: "..." });
await dust.merge("settings", { theme: "dark" });
await dust.delete("posts.old-draft");

// Counters
await dust.increment("stats.views");
await dust.increment("stats.views", 5);

// Sets
await dust.add("post.tags", "elixir");
await dust.remove("post.tags", "draft");

// Files
await dust.putFile("posts.hello.image", "/path/to/photo.jpg");
const ref = await dust.get("posts.hello.image");
const data = await ref.fetch();

// Typed values
await dust.put("product.price", new Dust.Decimal("29.99"));
await dust.put("post.published_at", new Date());

// Subscribe
dust.on("posts.*", (event) => {
  rebuildIndex(event);
});

// Enumerate
for (const [path, post] of dust.enum("posts.*")) {
  console.log(post.title);
}

// Audit log
await dust.log({ path: "posts.*", limit: 50 });

// Rollback
await dust.rollback("posts.hello", { toSeq: 40 });
await dust.rollback({ toSeq: 40 });  // whole store
```

## MCP Server

The Dust server exposes an MCP (Model Context Protocol) endpoint over HTTP, giving AI agents native access to stores. Any MCP-compatible client (Claude Code, Claude Desktop, Cursor, etc.) can read, write, subscribe, and manage stores. The MCP endpoint is the same REST API used internally — MCP is just another transport.

### Tools exposed

| Tool | Description |
|------|-------------|
| `dust_get` | Read a value at a path |
| `dust_put` | Write a value at a path |
| `dust_merge` | Merge keys into a map |
| `dust_delete` | Delete a path |
| `dust_enum` | Enumerate keys matching a glob pattern |
| `dust_increment` | Increment a counter |
| `dust_add` | Add a member to a set |
| `dust_remove` | Remove a member from a set |
| `dust_put_file` | Upload a file |
| `dust_fetch_file` | Download file content |
| `dust_log` | Query the audit log |
| `dust_rollback` | Rollback a path or store to a previous seq |
| `dust_stores` | List joined stores |
| `dust_status` | Sync status |
| `dust_watch` | Subscribe to changes (streaming) |

### Resources exposed

Stores and paths are exposed as MCP resources:

```
dust://james/blog/posts.hello          # a specific value
dust://james/blog/posts.*              # enumerable pattern
dust://james/blog                      # store root
```

### Configuration

```json
{
  "mcpServers": {
    "dust": {
      "type": "url",
      "url": "https://api.dust.dev/mcp",
      "headers": {
        "Authorization": "Bearer dust_tok_..."
      }
    }
  }
}
```

Full feature parity with the CLI and SDKs. An AI agent can do anything a human developer can.

## Authentication

### Human users

`dust login` performs OAuth/magic link authentication and generates a device keypair. One-time setup.

### Deployments

Set `DUST_API_KEY=dust_tok_...` as an environment variable. The SDK picks it up automatically. No config files, no JSON credentials, no initialization code.

### Scoped tokens

Generate tokens with per-store, per-permission scope:

```
$ dust token create --store james/blog --read --name blog-deploy
$ dust token create --store james/blog --read --write --name blog-admin
```

A deployment's token determines what it can access. Your blog deployment token can't write to your news translations.

## Audit Log

The op log is the audit trail. Every write is already recorded as `{store_seq, device_id, op, path, value, timestamp}`. The audit log is a read API over this existing data — no new infrastructure required.

Queries can filter by path, device, operation type, and time range. Results are returned in `store_seq` order.

Retention is tied to log compaction. Once ops are compacted into a snapshot, the individual operations are gone. Retention depth varies by tier:

| Tier | Op log retention |
|------|-----------------|
| Free | 7 days |
| Pro | 30 days |
| Team | 1 year |

## Rollback

Rollback restores state to what it looked like at a previous `store_seq`. It works at two granularities:

**Path-level rollback** restores a single key (or subtree) to its value at a given seq. The server looks up the historical value and writes a new `set` op. Everything else in the store is untouched.

**Store-level rollback** restores the entire store to a given seq. The server computes the diff between current state and the historical snapshot, then writes new ops that bring the state back. More destructive, but recoverable — the rollback itself is logged.

**Rollback is always a forward operation.** It never rewrites the op log. Rolling back to seq 40 creates new ops at the current seq that make the state match what seq 40 looked like. The audit trail is preserved — you can see who rolled back, when, and to what point. You can undo a rollback.

**Rollback only works within the retention window.** If the server has compacted beyond a given seq, individual ops before that point are gone. You can roll back to the compaction snapshot point or anything after it, but not before. Deeper retention means a deeper rollback window.

## Storage

### Server-side

- **Postgres** for metadata (accounts, devices, stores, membership, tokens), op log, and materialized map state.
- **Object storage (S3)** for file blobs, keyed by content hash. Content-addressed: identical files are stored once regardless of how many references point to them.
- Op log table per store: `{store_id, device_id, seq, op, path, value, store_seq}`.
- Materialized state snapshot rebuilt from the op log. Serves as the fast path for new clients joining (send snapshot + recent ops rather than replaying entire history).
- Log compaction: once all clients for a store have caught up past a snapshot point, older ops collapse into the snapshot. Unreferenced file blobs are garbage collected during compaction.
- Map values stored as `jsonb` (structured) or `bytea` (opaque).

### Client-side

All clients use a cache adapter for local persistence (see Architecture > Cache Adapters). The cache stores the materialized current state, pending outbound ops, and `last_store_seq` per store.

File blobs are **not** cached locally by default. The cache stores only the lightweight file references. Content is fetched on demand via `ref.fetch()`. Optional local blob caching can be enabled per store for use cases that need offline file access.

## Limit Enforcement

Limits are enforced against the materialized current store state, not raw write volume.

- A scalar leaf value counts as `1` key.
- A map contributes `1` key for each leaf beneath it.
- Interior map nodes are free.
- `delete(path)` removes all billed leaf keys beneath that subtree.
- `merge(path, map)` is charged only for newly created leaf paths.
- Updating an existing leaf never changes the key count.

The server checks each incoming op:

- `set` on a new path → check key count, reject if over limit.
- `set` on an existing path → always allow (it's an update).
- `delete` → always allow.
- `merge` → check if any new keys would be created, reject if over limit.

No separate metering system. The op log is the billing boundary.

Examples:

- `set("posts.hello", %{title: "Hello", body: "..."})` creates `2` keys (`posts.hello.title`, `posts.hello.body`).
- `merge("posts.hello", %{title: "Hi"})` creates `0` new keys if `title` already exists.
- `delete("posts")` removes every billed leaf under `posts`.

## Pricing

| Tier | Price | Stores | Devices | Keys/store | Value size | File storage | Log retention |
|------|-------|--------|---------|------------|------------|--------------|---------------|
| Free | $0 | 1 | 3 | 1,000 | 64KB | 100MB | 7 days |
| Pro | ~$5/mo | Unlimited | Unlimited | 100,000 | 64KB | 10GB | 30 days |
| Team | ~$10/user/mo | Shared stores, scoped tokens | Unlimited | 1,000,000 | 64KB | 100GB | 1 year |

### Cost Structure

Reads are local — they never hit the server. Writes are tiny MessagePack ops. The server is a relay, not a compute engine. Log compaction keeps storage bounded. File storage is content-addressed, so duplicates are free. SDKs and daemon are open source — the hosted sync is the product.
