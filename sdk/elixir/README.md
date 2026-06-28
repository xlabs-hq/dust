# Dust SDK for Elixir

Reactive state sync for Elixir and Phoenix apps. Connect to a Dust store, read and write data, and subscribe to changes with glob-pattern callbacks.

## Installation

```elixir
# mix.exs
def deps do
  [{:dustlayer, "~> 0.1"}]
end
```

## Setup

Generate the Dust module, config, and migration:

```bash
mix dust.install
```

Or configure manually:

```elixir
# lib/my_app/dust.ex
defmodule MyApp.Dust do
  use Dust, otp_app: :my_app
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Dust,
  stores: ["org/store"],
  repo: MyApp.Repo
```

```elixir
# lib/my_app/application.ex — add to children
MyApp.Dust
```

## Usage

```elixir
# Write
MyApp.Dust.put("org/store", "users/alice", %{name: "Alice", role: "admin"})

# Read (instant, from local cache)
{:ok, user} = MyApp.Dust.get("org/store", "users/alice")

# Delete
MyApp.Dust.delete("org/store", "users/alice")

# Merge (update children without replacing siblings)
MyApp.Dust.merge("org/store", "users/alice", %{"role" => "superadmin"})

# Enum (list matching entries)
entries = MyApp.Dust.enum("org/store", "users/*")

# Paginated enum
page = MyApp.Dust.enum("org/store", "users/**", limit: 20, order: :desc)

# Batch read
values = MyApp.Dust.get_many("org/store", ["users/alice", "users/bob"])

# Range read [from, to)
page = MyApp.Dust.range("org/store", "logs.2026-04-01", "logs.2026-04-30")

# Compare-and-swap
{:ok, entry} = MyApp.Dust.entry("org/store", "users/alice")
case MyApp.Dust.put("org/store", "users/alice", updated, if_match: entry.revision) do
  :ok -> :saved
  {:error, :conflict} -> :retry
end

# Put-new — claim a key only if it does not already exist (race-free).
# Returns {:error, :exists} if another writer got there first.
case MyApp.Dust.put("org/store", "locks/poll", node_id, if_absent: true) do
  {:ok, _seq} -> :i_won_the_claim
  {:error, :exists} -> :someone_else_holds_it
end

# Freshness — entry.synced_at is the local wall-clock (unix epoch ms) when
# this node last wrote the row from a sync event. Use it to reason about how
# stale the local mirror is (nil for subtree-assembled entries).
{:ok, entry} = MyApp.Dust.entry("org/store", "users/alice")
age_ms = System.system_time(:millisecond) - entry.synced_at

# Subscribe to changes
MyApp.Dust.on("org/store", "users/*", fn event ->
  IO.puts("#{event.path} changed: #{inspect(event.value)}")
end)
```

## Authentication and Capabilities

Tokens need `entries:read` to join and read a store. Add `entries:write` for
writes, leases, rollback, and `single_flight`.

```elixir
status = MyApp.Dust.status("org/store")
# %{
#   connection: :connected,
#   permissions: %{read: true, write: false},
#   scopes: ["entries:read"],
#   store_access: %{mode: :selected, store_ids: ["..."]}
# }

case MyApp.Dust.lease("org/store", "jobs/nightly") do
  {:error, {:missing_scope, "entries:write", message}} ->
    Logger.warning(message)

  other ->
    other
end
```

## Coordination: leases & single-flight

`single_flight` computes an expensive thing **once across your fleet** and
shares the result — replacing hand-rolled "check S3, maybe do the work,
coordinate with other nodes" schemes. It is **at-least-once while Dust is
reachable, not exactly-once**: `fun` must be idempotent and publish a small
pointer (keep the bytes in S3/your DB).

```elixir
# Done-forever (presence mode): OCR a PDF once per content hash.
{:ok, %Dust.Flight{value: manifest}} =
  MyApp.Dust.single_flight("org/store", "artifacts/#{hash}", fn _lease ->
    {:ok, keys} = download_and_ocr(hash)   # bytes stay in R2
    {:publish, %{"manifest" => keys}}      # publish a small pointer
  end, lease_ttl: :timer.minutes(20))      # heartbeat-renewed while it runs

# Fresh-within-a-window (freshness mode): poll a Facebook page at most hourly,
# shared across prod + staging. The value carries its own timestamp.
MyApp.Dust.single_flight("org/store", "pages/#{slug}", fn _lease ->
  {:publish, %{"posts" => poll(slug), "fetched_at" => System.system_time(:millisecond)}}
end,
  fresh?: fn v -> System.system_time(:millisecond) - v["fetched_at"] < :timer.hours(1) end,
  lease_ttl: :timer.minutes(5),
  on_unavailable: :run_local)              # never block; pay-once-per-node when Dust is down
```

`fun` returns `{:publish, value}` (store + share it) or `{:abort, reason}`
(release the lease, publish nothing). **Prefer `{:abort, _}` over raising**
for transient failures — abort releases immediately (waiters re-elect at
once); a raised `fun` only frees the lease at `lease_ttl`. Map definitive
negatives to `{:publish}` (so the freshness window holds) and transient ones
to `{:abort}` (so they aren't cached).

The low-level lease underneath is also available directly:

```elixir
case MyApp.Dust.lease("org/store", "jobs/nightly", ttl_ms: 60_000) do
  {:ok, lease} ->
    do_work()
    MyApp.Dust.put("org/store", "jobs/nightly/result", result, fence: lease)
    MyApp.Dust.release("org/store", lease)

  {:error, :held} -> :someone_else_has_it
end
```

`single_flight` uses the same lease/write path, so it also requires
`entries:write`. Missing write scope returns
`{:error, {:missing_scope, "entries:write", message}}`; it does not trigger
the `on_unavailable: :run_local` fallback.

`fence: lease` rejects a write (`{:error, :fenced}`) if the lease was lost
mid-run, so a stale holder can't clobber a newer one's result.

## Upgrading

### `synced_at` cache column

The cache row gained a `synced_at` column (local wall-clock, unix epoch ms,
surfaced as `Dust.Entry.synced_at`). Fresh installs get it automatically.
**Existing adopters must add the column** before upgrading — generate a
migration and add:

```elixir
alter table(:dust_cache) do
  add :synced_at, :bigint
end
```

The column is nullable, so rows written before the upgrade read back
`synced_at: nil`.

## Full Documentation

See the [main Dust README](../../README.md) for the complete API reference, type system (counters, sets, decimals, files), Phoenix PubSub integration, declarative subscribers, audit log, and testing helpers.
