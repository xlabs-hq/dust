# Dust SDK for Elixir

Reactive state sync for Elixir and Phoenix apps. Connect to a Dust store, read and write data, and subscribe to changes with glob-pattern callbacks.

## Installation

```elixir
# mix.exs
def deps do
  [{:dust, "~> 0.1"}]
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
MyApp.Dust.put("org/store", "users.alice", %{name: "Alice", role: "admin"})

# Read (instant, from local cache)
{:ok, user} = MyApp.Dust.get("org/store", "users.alice")

# Delete
MyApp.Dust.delete("org/store", "users.alice")

# Merge (update children without replacing siblings)
MyApp.Dust.merge("org/store", "users.alice", %{"role" => "superadmin"})

# Enum (list matching entries)
entries = MyApp.Dust.enum("org/store", "users.*")

# Paginated enum
page = MyApp.Dust.enum("org/store", "users.**", limit: 20, order: :desc)

# Batch read
values = MyApp.Dust.get_many("org/store", ["users.alice", "users.bob"])

# Range read [from, to)
page = MyApp.Dust.range("org/store", "logs.2026-04-01", "logs.2026-04-30")

# Compare-and-swap
{:ok, entry} = MyApp.Dust.entry("org/store", "users.alice")
case MyApp.Dust.put("org/store", "users.alice", updated, if_match: entry.revision) do
  :ok -> :saved
  {:error, :conflict} -> :retry
end

# Subscribe to changes
MyApp.Dust.on("org/store", "users.*", fn event ->
  IO.puts("#{event.path} changed: #{inspect(event.value)}")
end)
```

## Full Documentation

See the [main Dust README](../../README.md) for the complete API reference, type system (counters, sets, decimals, files), Phoenix PubSub integration, declarative subscribers, audit log, and testing helpers.
