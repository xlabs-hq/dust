# Dust Phase 3 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a polished Phoenix integration layer to the Elixir SDK (facade module, declarative subscribers, PubSub bridge, test harness, Igniter installer) and build a standalone Crystal CLI that speaks the Dust wire protocol natively.

**Architecture:** The Phoenix integration extends `sdk/elixir/` with optional modules — no new package. The `use Dust` macro generates a facade module that wraps supervision, configuration, and subscriber wiring. The Crystal CLI is a new project in `cli/` that implements the Phoenix Channel v2 JSON protocol over WebSocket with a SQLite local cache.

**Tech Stack:** Elixir SDK: Phoenix (optional), Ecto (optional), Igniter (optional). Crystal CLI: Crystal lang, stdlib HTTP::WebSocket, sqlite3 shard.

**Reference docs:**
- Design: `docs/plans/2026-03-31-dust-phase3-design.md`
- Product spec: `docs/plans/2026-03-26-dust-design-v4.md`
- Protocol: `protocol/spec/sync-semantics.md`, `protocol/spec/asyncapi.yaml`

---

## Task 1: `use Dust` Facade Module

The core macro that creates a named Dust instance from app config — like `use Oban` or `use Cloak.Vault`.

**Files:**
- Create: `sdk/elixir/lib/dust/instance.ex`
- Modify: `sdk/elixir/lib/dust.ex`
- Test: `sdk/elixir/test/dust/instance_test.exs`

### Step 1: Write failing test

`sdk/elixir/test/dust/instance_test.exs`:

```elixir
defmodule Dust.InstanceTest do
  use ExUnit.Case

  defmodule TestDust do
    use Dust, otp_app: :dust_test
  end

  setup do
    Application.put_env(:dust_test, TestDust,
      stores: ["test/store"],
      cache: {Dust.Cache.Memory, []},
      testing: :manual
    )

    start_supervised!(TestDust)
    :ok
  end

  test "facade module delegates to SyncEngine" do
    :ok = TestDust.put("test/store", "key", "value")
    assert {:ok, "value"} = TestDust.get("test/store", "key")
  end

  test "facade module exposes status" do
    status = TestDust.status("test/store")
    assert status.connection == :disconnected
    assert status.last_store_seq == 0
  end

  test "child_spec reads from app config" do
    spec = TestDust.child_spec([])
    assert spec.id == TestDust
  end
end
```

### Step 2: Implement the `use Dust` macro

`sdk/elixir/lib/dust/instance.ex`:

```elixir
defmodule Dust.Instance do
  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      @otp_app unquote(otp_app)

      def child_spec(runtime_opts) do
        config = Application.fetch_env!(@otp_app, __MODULE__)
        merged = Keyword.merge(config, runtime_opts)

        %{
          id: __MODULE__,
          start: {Dust.Supervisor, :start_link, [merged ++ [name: __MODULE__]]},
          type: :supervisor
        }
      end

      def start_link(runtime_opts \\ []) do
        config = Application.fetch_env!(@otp_app, __MODULE__)
        merged = Keyword.merge(config, runtime_opts)
        Dust.Supervisor.start_link(merged ++ [name: __MODULE__])
      end

      # Delegate all public API functions
      defdelegate get(store, path), to: Dust.SyncEngine
      defdelegate put(store, path, value), to: Dust.SyncEngine
      defdelegate delete(store, path), to: Dust.SyncEngine
      defdelegate merge(store, path, map), to: Dust.SyncEngine
      defdelegate increment(store, path, delta \\ 1), to: Dust.SyncEngine
      defdelegate add(store, path, member), to: Dust.SyncEngine
      defdelegate remove(store, path, member), to: Dust.SyncEngine
      defdelegate put_file(store, path, source_path), to: Dust.SyncEngine
      defdelegate put_file(store, path, source_path, opts), to: Dust.SyncEngine
      defdelegate on(store, pattern, callback, opts \\ []), to: Dust.SyncEngine
      defdelegate enum(store, pattern), to: Dust.SyncEngine
      defdelegate status(store), to: Dust.SyncEngine
    end
  end
end
```

Update `sdk/elixir/lib/dust.ex` to wire in the macro:

```elixir
defmodule Dust do
  @moduledoc "Dust SDK — reactive global map client."

  defmacro __using__(opts) do
    quote do
      use Dust.Instance, unquote(opts)
    end
  end

  # Keep existing direct API for non-facade usage
  # ...existing defdelegate calls...
end
```

### Step 3: Update Supervisor to accept `:name` and `:testing` options

Modify `sdk/elixir/lib/dust/supervisor.ex`:
- Accept `:name` option for named supervisor (so multiple instances don't collide)
- When `testing: :manual`, skip starting the Connection process and use Memory cache if no cache specified
- Derive unique registry names from the supervisor name to avoid conflicts

### Step 4: Run tests, verify they pass

```bash
cd sdk/elixir && mix test test/dust/instance_test.exs
```

### Step 5: Commit

```bash
git add sdk/elixir/
git commit -m "feat: add use Dust facade macro with config-driven setup"
```

---

## Task 2: Declarative Subscribers

Module-based callback handlers that register automatically from config.

**Files:**
- Create: `sdk/elixir/lib/dust/subscriber.ex`
- Test: `sdk/elixir/test/dust/subscriber_test.exs`

### Step 1: Write failing test

```elixir
defmodule Dust.SubscriberTest do
  use ExUnit.Case

  defmodule TestSubscriber do
    use Dust.Subscriber,
      store: "test/store",
      pattern: "posts.*"

    @impl true
    def handle_event(event) do
      send(event.meta.test_pid, {:subscriber_called, event})
      :ok
    end
  end

  defmodule SubscriberDust do
    use Dust, otp_app: :dust_subscriber_test
  end

  setup do
    Application.put_env(:dust_subscriber_test, SubscriberDust,
      stores: ["test/store"],
      cache: {Dust.Cache.Memory, []},
      testing: :manual,
      subscribers: [TestSubscriber]
    )

    start_supervised!(SubscriberDust)
    :ok
  end

  test "subscriber module declares store and pattern" do
    assert TestSubscriber.__dust_store__() == "test/store"
    assert TestSubscriber.__dust_pattern__() == "posts.*"
  end

  test "subscriber is called when matching event is emitted" do
    # Use Dust.Testing.emit to trigger a server event
    Dust.Testing.emit("test/store", "posts.hello",
      op: :set,
      value: %{"title" => "Hello"},
      meta: %{test_pid: self()}
    )

    assert_receive {:subscriber_called, event}, 500
    assert event.path == "posts.hello"
    assert event.value == %{"title" => "Hello"}
  end

  test "subscriber is NOT called for non-matching paths" do
    Dust.Testing.emit("test/store", "config.x",
      op: :set,
      value: "val",
      meta: %{test_pid: self()}
    )

    refute_receive {:subscriber_called, _}, 100
  end
end
```

### Step 2: Implement Subscriber macro

`sdk/elixir/lib/dust/subscriber.ex`:

```elixir
defmodule Dust.Subscriber do
  @callback handle_event(event :: map()) :: :ok | {:error, term()}

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)
    pattern = Keyword.fetch!(opts, :pattern)
    max_queue_size = Keyword.get(opts, :max_queue_size, 1000)

    quote do
      @behaviour Dust.Subscriber

      def __dust_store__, do: unquote(store)
      def __dust_pattern__, do: unquote(pattern)
      def __dust_max_queue_size__, do: unquote(max_queue_size)

      def __dust_register__(dust_module) do
        Dust.SyncEngine.on(
          __dust_store__(),
          __dust_pattern__(),
          fn event -> __MODULE__.handle_event(event) end,
          max_queue_size: __dust_max_queue_size__()
        )
      end
    end
  end
end
```

### Step 3: Wire subscriber registration into Supervisor

When the Supervisor starts, after SyncEngines are up, register each subscriber module from the `:subscribers` config list by calling `module.__dust_register__/1`.

### Step 4: Run tests, verify they pass

```bash
cd sdk/elixir && mix test test/dust/subscriber_test.exs
```

### Step 5: Commit

```bash
git add sdk/elixir/
git commit -m "feat: add declarative Dust.Subscriber modules with auto-registration"
```

---

## Task 3: Test Harness

The `Dust.Testing` module with `seed/2`, `emit/3`, `set_status/3` primitives.

**Files:**
- Create: `sdk/elixir/lib/dust/testing.ex`
- Test: `sdk/elixir/test/dust/testing_test.exs`

### Step 1: Write failing test

```elixir
defmodule Dust.TestingTest do
  use ExUnit.Case

  defmodule TestDust do
    use Dust, otp_app: :dust_testing_test
  end

  setup do
    Application.put_env(:dust_testing_test, TestDust,
      stores: ["test/store"],
      testing: :manual
    )

    start_supervised!(TestDust)
    :ok
  end

  test "seed populates cache for get" do
    Dust.Testing.seed("test/store", %{
      "posts.hello" => %{"title" => "Hello"},
      "posts.goodbye" => %{"title" => "Goodbye"}
    })

    assert {:ok, %{"title" => "Hello"}} = TestDust.get("test/store", "posts.hello")
    assert {:ok, %{"title" => "Goodbye"}} = TestDust.get("test/store", "posts.goodbye")
  end

  test "seed populates cache for enum" do
    Dust.Testing.seed("test/store", %{
      "posts.a" => "1",
      "posts.b" => "2",
      "config.x" => "3"
    })

    results = TestDust.enum("test/store", "posts.*")
    assert length(results) == 2
  end

  test "emit triggers subscriber callbacks synchronously" do
    test_pid = self()

    TestDust.on("test/store", "posts.*", fn event ->
      send(test_pid, {:event_received, event})
    end)

    Dust.Testing.emit("test/store", "posts.hello",
      op: :set,
      value: %{"title" => "New"}
    )

    assert_receive {:event_received, %{path: "posts.hello", value: %{"title" => "New"}}}, 100
  end

  test "emit updates cache state" do
    Dust.Testing.emit("test/store", "key",
      op: :set,
      value: "from_server"
    )

    assert {:ok, "from_server"} = TestDust.get("test/store", "key")
  end

  test "set_status controls status response" do
    Dust.Testing.set_status("test/store", :connected, store_seq: 42)

    status = TestDust.status("test/store")
    assert status.connection == :connected
    assert status.last_store_seq == 42
  end
end
```

### Step 2: Implement Dust.Testing

`sdk/elixir/lib/dust/testing.ex`:

```elixir
defmodule Dust.Testing do
  @moduledoc """
  Test helpers for applications that use Dust.
  In :manual test mode, Dust uses a memory cache and no server connection.
  Use these functions to control Dust state in tests.
  """

  @doc "Populate the cache with known state. get/enum will return this data."
  def seed(store, entries) when is_map(entries) do
    Enum.each(entries, fn {path, value} ->
      type = detect_type(value)
      Dust.SyncEngine.seed_entry(store, path, value, type)
    end)
    :ok
  end

  @doc "Fire an event through the subscriber pipeline as if the server sent it. Synchronous."
  def emit(store, path, opts \\ []) do
    op = Keyword.get(opts, :op, :set)
    value = Keyword.get(opts, :value)
    meta = Keyword.get(opts, :meta, %{})

    event = %{
      "store" => store,
      "path" => path,
      "op" => to_string(op),
      "value" => value,
      "store_seq" => System.unique_integer([:positive]),
      "device_id" => "test",
      "client_op_id" => "test_#{System.unique_integer([:positive])}"
    }
    |> Map.merge(if meta != %{}, do: %{"meta" => meta}, else: %{})

    Dust.SyncEngine.handle_server_event(store, event)
    :ok
  end

  @doc "Control what Dust.status/1 returns."
  def set_status(store, connection_status, opts \\ []) do
    store_seq = Keyword.get(opts, :store_seq, 0)
    Dust.SyncEngine.set_status(store, connection_status)
    # If store_seq provided, we need to update last_store_seq too
    if store_seq > 0 do
      Dust.SyncEngine.set_store_seq(store, store_seq)
    end
    :ok
  end

  @doc "Build an event map for testing subscriber modules in isolation."
  def build_event(store, path, opts \\ []) do
    %{
      store: store,
      path: path,
      op: Keyword.get(opts, :op, :set),
      value: Keyword.get(opts, :value),
      store_seq: Keyword.get(opts, :store_seq, 1),
      committed: true,
      source: :server,
      device_id: "test",
      client_op_id: "test"
    }
  end

  defp detect_type(v) when is_map(v), do: "map"
  defp detect_type(v) when is_binary(v), do: "string"
  defp detect_type(v) when is_integer(v), do: "integer"
  defp detect_type(v) when is_float(v), do: "float"
  defp detect_type(v) when is_boolean(v), do: "boolean"
  defp detect_type(nil), do: "null"
  defp detect_type(_), do: "string"
end
```

### Step 3: Add `seed_entry/4` and `set_store_seq/2` to SyncEngine

These are test-support functions that write directly to the cache and state without going through the normal write path:

```elixir
def seed_entry(store, path, value, type) do
  GenServer.call(via(store), {:seed_entry, path, value, type})
end

def set_store_seq(store, seq) do
  GenServer.cast(via(store), {:set_store_seq, seq})
end
```

### Step 4: Run tests, verify they pass

```bash
cd sdk/elixir && mix test test/dust/testing_test.exs
```

### Step 5: Commit

```bash
git add sdk/elixir/
git commit -m "feat: add Dust.Testing harness with seed, emit, and set_status"
```

---

## Task 4: PubSub Bridge

Broadcast Dust events to Phoenix.PubSub when configured.

**Files:**
- Create: `sdk/elixir/lib/dust/pubsub_bridge.ex`
- Modify: `sdk/elixir/lib/dust/supervisor.ex`
- Test: `sdk/elixir/test/dust/pubsub_bridge_test.exs`

### Step 1: Write failing test

```elixir
defmodule Dust.PubSubBridgeTest do
  use ExUnit.Case

  defmodule BridgeDust do
    use Dust, otp_app: :dust_pubsub_test
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: Dust.TestPubSub})

    Application.put_env(:dust_pubsub_test, BridgeDust,
      stores: ["test/store"],
      testing: :manual,
      pubsub: Dust.TestPubSub
    )

    start_supervised!(BridgeDust)
    :ok
  end

  test "dust events broadcast to PubSub" do
    Phoenix.PubSub.subscribe(Dust.TestPubSub, "dust:test/store:posts.*")

    Dust.Testing.emit("test/store", "posts.hello",
      op: :set,
      value: %{"title" => "Hello"}
    )

    assert_receive {:dust_event, event}, 500
    assert event.path == "posts.hello"
    assert event.value == %{"title" => "Hello"}
  end

  test "non-matching patterns do not receive events" do
    Phoenix.PubSub.subscribe(Dust.TestPubSub, "dust:test/store:config.*")

    Dust.Testing.emit("test/store", "posts.hello",
      op: :set,
      value: "val"
    )

    refute_receive {:dust_event, _}, 100
  end
end
```

### Step 2: Implement PubSub bridge

`sdk/elixir/lib/dust/pubsub_bridge.ex`:

The bridge registers as a Dust callback (via `Dust.on/3`) for each store with pattern `**` (all events). When an event arrives, it broadcasts to the PubSub topic `"dust:{store}:{path}"`. PubSub subscribers use glob-like topic matching — but Phoenix.PubSub doesn't natively support globs. Instead, broadcast to `"dust:{store}"` as the topic and let subscribers filter, OR broadcast to the exact path and let subscribers use `Phoenix.PubSub.subscribe` with the specific pattern they care about.

Simplest approach: broadcast to `"dust:{store}"` for all events. Subscribers filter in their `handle_info`. This matches how Phoenix Channels work — subscribe to a topic, filter messages yourself.

Actually, the design says topic format is `"dust:{store}:{pattern}"`. The bridge should broadcast to a topic per event path so subscribers can be selective. But PubSub topics are exact — no globs. So broadcast to `"dust:{store}:{path}"` and subscribers subscribe to the exact paths they want, OR use a registry-based approach.

**Pragmatic approach:** Broadcast every event to `"dust:{store}"`. Subscribers subscribe once per store and filter in their `handle_info`. Simple, no magic.

### Step 3: Wire into Supervisor

When `pubsub` is configured, start the bridge as a subscriber for each store.

### Step 4: Add `{:phoenix_pubsub, "~> 2.0"}` as optional dep

```elixir
{:phoenix_pubsub, "~> 2.0", optional: true}
```

### Step 5: Run tests, verify they pass

```bash
cd sdk/elixir && mix test test/dust/pubsub_bridge_test.exs
```

### Step 6: Commit

```bash
git add sdk/elixir/
git commit -m "feat: add PubSub bridge — Dust events broadcast to Phoenix.PubSub"
```

---

## Task 5: Igniter Installer

`mix dust.install` that patches config, supervision tree, and generates files.

**Files:**
- Create: `sdk/elixir/lib/mix/tasks/dust.install.ex`
- Modify: `sdk/elixir/mix.exs` (add igniter as optional dep)

### Step 1: Add Igniter dependency

```elixir
{:igniter, "~> 0.5", optional: true, runtime: false}
```

### Step 2: Implement the installer

`sdk/elixir/lib/mix/tasks/dust.install.ex`:

```elixir
defmodule Mix.Tasks.Dust.Install do
  use Mix.Task

  @shortdoc "Sets up Dust in your Phoenix application"

  def run(args) do
    if Code.ensure_loaded?(Igniter) do
      run_with_igniter(args)
    else
      run_without_igniter(args)
    end
  end

  defp run_with_igniter(_args) do
    app = Mix.Project.config()[:app]
    module = app |> to_string() |> Macro.camelize()
    dust_module = "#{module}.Dust"

    Igniter.new()
    |> Igniter.create_new_file("lib/#{app}/dust.ex", """
    defmodule #{dust_module} do
      use Dust, otp_app: :#{app}
    end
    """)
    |> Igniter.update_file("config/config.exs", fn source ->
      # Add Dust config
      Igniter.Code.append_to_file(source, """

      config :#{app}, #{dust_module},
        stores: [],
        repo: #{module}.Repo
      """)
    end)
    |> Igniter.update_file("config/test.exs", fn source ->
      Igniter.Code.append_to_file(source, """

      config :#{app}, #{dust_module}, testing: :manual
      """)
    end)
    # Generate migration
    |> generate_migration(app)
    |> Igniter.execute()
  end

  defp run_without_igniter(_args) do
    # Fallback: generate files and print instructions
    app = Mix.Project.config()[:app]
    module = app |> to_string() |> Macro.camelize()

    # Generate migration
    Mix.Task.run("dust.gen.migration")

    # Print manual setup instructions
    Mix.shell().info("""

    Dust installed! Complete setup:

    1. Add to your supervision tree in lib/#{app}/application.ex:

        children = [
          #{module}.Repo,
          #{module}.Dust,
          #{module}Web.Endpoint
        ]

    2. Add config to config/config.exs:

        config :#{app}, #{module}.Dust,
          stores: ["your/store"],
          repo: #{module}.Repo

    3. Add test config to config/test.exs:

        config :#{app}, #{module}.Dust, testing: :manual

    4. Create lib/#{app}/dust.ex:

        defmodule #{module}.Dust do
          use Dust, otp_app: :#{app}
        end

    5. Run migrations:

        mix ecto.migrate
    """)
  end
end
```

### Step 3: Test manually

```bash
# In a test Phoenix project:
mix dust.install
```

### Step 4: Commit

```bash
git add sdk/elixir/
git commit -m "feat: add mix dust.install with Igniter support"
```

---

## Task 6: Crystal CLI — Project Setup + Config

Initialize the Crystal project with dependency management, config handling, and credential storage.

**Files:**
- Create: `cli/shard.yml`
- Create: `cli/src/dust.cr`
- Create: `cli/src/dust/config.cr`
- Create: `cli/src/dust/cli.cr`
- Create: `cli/spec/config_spec.cr`

### Step 1: Create shard.yml

```yaml
name: dust
version: 0.1.0

targets:
  dust:
    main: src/dust.cr

dependencies:
  sqlite3:
    github: crystal-lang/crystal-sqlite3

crystal: ">= 1.12.0"

license: MIT
```

### Step 2: Create config module

`cli/src/dust/config.cr`:

```crystal
module Dust
  class Config
    CONFIG_DIR = Path.join(ENV.fetch("XDG_CONFIG_HOME", Path.join(ENV["HOME"], ".config")), "dust")
    DATA_DIR = Path.join(ENV.fetch("XDG_DATA_HOME", Path.join(ENV["HOME"], ".local/share")), "dust")
    CREDENTIALS_FILE = Path.join(CONFIG_DIR, "credentials.json")
    CONFIG_FILE = Path.join(CONFIG_DIR, "config.json")

    property token : String?
    property device_id : String
    property server_url : String

    def initialize
      @token = ENV["DUST_API_KEY"]?
      @device_id = "dev_" + Random::Secure.hex(8)
      @server_url = "ws://localhost:7755/ws/sync"
      load_credentials
      load_config
    end

    def save_credentials(token : String)
      Dir.mkdir_p(CONFIG_DIR)
      File.write(CREDENTIALS_FILE, {
        token: token,
        device_id: @device_id,
        server_url: @server_url
      }.to_json)
      @token = token
    end

    def authenticated? : Bool
      !@token.nil?
    end

    private def load_credentials
      return unless File.exists?(CREDENTIALS_FILE)
      data = JSON.parse(File.read(CREDENTIALS_FILE))
      @token ||= data["token"]?.try(&.as_s)
      @device_id = data["device_id"]?.try(&.as_s) || @device_id
      @server_url = data["server_url"]?.try(&.as_s) || @server_url
    end

    private def load_config
      return unless File.exists?(CONFIG_FILE)
      data = JSON.parse(File.read(CONFIG_FILE))
      @server_url = data["server_url"]?.try(&.as_s) || @server_url
    end
  end
end
```

### Step 3: Create entry point and CLI router

`cli/src/dust.cr`:

```crystal
require "./dust/*"
require "./dust/commands/*"
require "./dust/client/*"
require "./dust/cache/*"

Dust::CLI.run(ARGV)
```

`cli/src/dust/cli.cr`:

```crystal
module Dust
  class CLI
    def self.run(args : Array(String))
      if args.empty?
        print_usage
        return
      end

      config = Config.new
      command = args[0]
      rest = args[1..]

      case command
      when "login"    then Commands::Auth.login(config)
      when "logout"   then Commands::Auth.logout(config)
      when "create"   then Commands::Store.create(config, rest)
      when "stores"   then Commands::Store.list(config)
      when "status"   then Commands::Store.status(config, rest)
      when "put"      then Commands::Data.put(config, rest)
      when "get"      then Commands::Data.get(config, rest)
      when "merge"    then Commands::Data.merge(config, rest)
      when "delete"   then Commands::Data.delete(config, rest)
      when "enum"     then Commands::Data.enum(config, rest)
      when "watch"    then Commands::Watch.run(config, rest)
      when "log"      then Commands::Log.run(config, rest)
      when "rollback" then Commands::Log.rollback(config, rest)
      when "increment" then Commands::Types.increment(config, rest)
      when "add"       then Commands::Types.add(config, rest)
      when "remove"    then Commands::Types.remove(config, rest)
      when "put-file"   then Commands::Files.put(config, rest)
      when "fetch-file" then Commands::Files.fetch(config, rest)
      when "token"      then Commands::Token.run(config, rest)
      when "help", "--help", "-h" then print_usage
      when "version", "--version" then puts "dust 0.1.0"
      else
        STDERR.puts "Unknown command: #{command}"
        print_usage
        exit 1
      end
    end

    def self.print_usage
      puts <<-USAGE
      dust — reactive global map CLI

      Usage: dust <command> [arguments]

      Commands:
        login                         Authenticate with Dust
        logout                        Clear credentials
        create <store>                Create a store
        stores                        List stores
        status [store]                Show sync status

        put <store> <path> <json>     Set a value
        get <store> <path>            Read a value
        merge <store> <path> <json>   Merge keys
        delete <store> <path>         Delete a path
        enum <store> <pattern>        List matching entries

        increment <store> <path> [n]  Increment counter
        add <store> <path> <member>   Add to set
        remove <store> <path> <member> Remove from set

        put-file <store> <path> <file> Upload file
        fetch-file <store> <path> <dest> Download file

        watch <store> <pattern>       Stream changes
        log <store> [options]         Audit log
        rollback <store> [options]    Rollback

        token create|list|revoke      Manage tokens

      USAGE
    end
  end
end
```

### Step 4: Write spec and verify build

```crystal
# cli/spec/config_spec.cr
require "spec"
require "../src/dust/config"

describe Dust::Config do
  it "creates a new config with defaults" do
    config = Dust::Config.new
    config.server_url.should eq "ws://localhost:7755/ws/sync"
    config.authenticated?.should be_false
  end
end
```

```bash
cd cli && shards install && crystal spec
```

### Step 5: Commit

```bash
git add cli/
git commit -m "feat: initialize Crystal CLI project with config and command routing"
```

---

## Task 7: Crystal CLI — Phoenix Channel Client

The WebSocket client that speaks Phoenix Channel v2 JSON protocol.

**Files:**
- Create: `cli/src/dust/client/connection.cr`
- Create: `cli/src/dust/client/channel.cr`
- Create: `cli/spec/client/channel_spec.cr`

### Step 1: Implement Channel protocol

`cli/src/dust/client/channel.cr`:

```crystal
module Dust
  class Channel
    @ref : Int32 = 0
    @join_ref : String? = nil
    @pending : Hash(String, Channel(JSON::Any)) = {} of String => Channel(JSON::Any)

    getter topic : String

    def initialize(@ws : HTTP::WebSocket, @topic : String)
    end

    def join(payload : Hash = {} of String => JSON::Any)
      ref = next_ref
      @join_ref = ref
      send_message(@join_ref, ref, @topic, "phx_join", payload)
      # Wait for reply
    end

    def push(event : String, payload : Hash)
      ref = next_ref
      send_message(nil, ref, @topic, event, payload)
      ref
    end

    def leave
      ref = next_ref
      send_message(@join_ref, ref, @topic, "phx_leave", {} of String => JSON::Any)
    end

    private def send_message(join_ref, ref, topic, event, payload)
      msg = [join_ref, ref, topic, event, payload]
      @ws.send(msg.to_json)
    end

    private def next_ref : String
      @ref += 1
      @ref.to_s
    end
  end
end
```

`cli/src/dust/client/connection.cr`:

```crystal
module Dust
  class Connection
    @ws : HTTP::WebSocket?
    @channels : Hash(String, Channel) = {} of String => Channel
    @heartbeat_fiber : Fiber?

    def initialize(@config : Config)
    end

    def connect
      uri = build_uri
      @ws = HTTP::WebSocket.new(uri)
      start_heartbeat
      spawn { listen }
    end

    def join(store : String, last_store_seq : Int64 = 0_i64) : Channel
      ws = @ws.not_nil!
      topic = "store:#{store}"
      channel = Channel.new(ws, topic)
      channel.join({"last_store_seq" => JSON::Any.new(last_store_seq)})
      @channels[topic] = channel
      channel
    end

    def close
      @ws.try(&.close)
    end

    private def build_uri : URI
      base = URI.parse(@config.server_url)
      params = URI::Params.build do |p|
        p.add "token", @config.token.not_nil!
        p.add "device_id", @config.device_id
        p.add "capver", "1"
        p.add "vsn", "2.0.0"
      end
      base.path = (base.path || "") + "/websocket"
      base.query = params.to_s
      base
    end

    private def start_heartbeat
      @heartbeat_fiber = spawn do
        loop do
          sleep 30.seconds
          @ws.try do |ws|
            msg = [nil, next_ref, "phoenix", "heartbeat", {} of String => String]
            ws.send(msg.to_json)
          end
        end
      end
    end

    private def listen
      @ws.not_nil!.on_message do |message|
        handle_message(JSON.parse(message))
      end
      @ws.not_nil!.run
    end

    private def handle_message(msg : JSON::Any)
      # msg is [join_ref, ref, topic, event, payload]
      arr = msg.as_a
      topic = arr[2].as_s
      event = arr[3].as_s
      payload = arr[4]

      case event
      when "phx_reply"
        # Handle join replies and push replies
      when "event"
        # Handle server events — dispatch to callbacks
      when "phx_error"
        # Handle errors
      when "phx_close"
        # Handle topic close
      end
    end

    @ref_counter : Int32 = 0
    private def next_ref : String
      @ref_counter += 1
      @ref_counter.to_s
    end
  end
end
```

### Step 2: Write spec

Test the message framing (unit test, no real server):

```crystal
describe Dust::Channel do
  it "formats join message correctly" do
    # Test that the JSON array format is correct
  end
end
```

### Step 3: Commit

```bash
git add cli/
git commit -m "feat: add Phoenix Channel v2 WebSocket client in Crystal"
```

---

## Task 8: Crystal CLI — SQLite Cache

Local cache using the same `dust_cache` table schema.

**Files:**
- Create: `cli/src/dust/cache/sqlite.cr`
- Create: `cli/spec/cache/sqlite_spec.cr`

### Step 1: Implement SQLite cache

`cli/src/dust/cache/sqlite.cr`:

```crystal
require "sqlite3"

module Dust
  class Cache
    @db : DB::Database

    def initialize(path : String? = nil)
      db_path = path || Path.join(Config::DATA_DIR, "cache.db")
      Dir.mkdir_p(File.dirname(db_path))
      @db = DB.open("sqlite3://#{db_path}")
      migrate
    end

    def read(store : String, path : String) : JSON::Any?
      @db.query_one?(
        "SELECT value FROM dust_cache WHERE store = ? AND path = ?",
        store, path
      ) do |rs|
        JSON.parse(rs.read(String))
      end
    end

    def write(store : String, path : String, value : JSON::Any, type : String, seq : Int64)
      @db.exec(
        "INSERT INTO dust_cache (store, path, value, type, seq) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(store, path) DO UPDATE SET value = excluded.value, type = excluded.type, seq = excluded.seq",
        store, path, value.to_json, type, seq
      )
    end

    def delete(store : String, path : String)
      @db.exec("DELETE FROM dust_cache WHERE store = ? AND path = ?", store, path)
    end

    def last_seq(store : String) : Int64
      @db.query_one?(
        "SELECT seq FROM dust_cache WHERE store = ? AND path = ?",
        store, "_dust:last_seq"
      ) do |rs|
        rs.read(Int64)
      end || 0_i64
    end

    def close
      @db.close
    end

    private def migrate
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS dust_cache (
          store TEXT NOT NULL,
          path TEXT NOT NULL,
          value TEXT NOT NULL,
          type TEXT NOT NULL,
          seq INTEGER NOT NULL,
          PRIMARY KEY (store, path)
        )
      SQL
    end
  end
end
```

### Step 2: Write spec

```crystal
describe Dust::Cache do
  it "round-trips a value" do
    cache = Dust::Cache.new(":memory:")
    cache.write("s", "key", JSON::Any.new("val"), "string", 1_i64)
    cache.read("s", "key").should eq JSON::Any.new("val")
  end

  it "returns nil for missing key" do
    cache = Dust::Cache.new(":memory:")
    cache.read("s", "missing").should be_nil
  end
end
```

### Step 3: Commit

```bash
git add cli/
git commit -m "feat: add SQLite cache for Crystal CLI"
```

---

## Task 9: Crystal CLI — Core Commands

Implement put, get, merge, delete, enum using the Channel client.

**Files:**
- Create: `cli/src/dust/commands/data.cr`
- Create: `cli/src/dust/commands/store.cr`
- Create: `cli/src/dust/commands/auth.cr`
- Create: `cli/src/dust/output.cr`

### Step 1: Implement output helpers

`cli/src/dust/output.cr`:

```crystal
module Dust
  module Output
    def self.json(data)
      puts data.to_pretty_json
    end

    def self.error(message : String)
      STDERR.puts "Error: #{message}"
      exit 1
    end

    def self.success(message : String)
      puts message
    end

    def self.require_auth!(config : Config)
      unless config.authenticated?
        error("Not authenticated. Run 'dust login' first.")
      end
    end

    def self.require_args!(args : Array(String), min : Int32, usage : String)
      if args.size < min
        error("Usage: #{usage}")
      end
    end
  end
end
```

### Step 2: Implement data commands

`cli/src/dust/commands/data.cr`:

```crystal
module Dust::Commands
  module Data
    def self.put(config : Config, args : Array(String))
      Output.require_auth!(config)
      Output.require_args!(args, 3, "dust put <store> <path> <json>")

      store, path, value_str = args[0], args[1], args[2]
      value = JSON.parse(value_str)

      conn = Connection.new(config)
      conn.connect
      channel = conn.join(store)

      reply = channel.push("write", {
        "op" => "set",
        "path" => path,
        "value" => value,
        "client_op_id" => "cli_#{Random::Secure.hex(8)}"
      })

      Output.success("Set #{store}/#{path} (seq: #{reply["store_seq"]})")
      conn.close
    end

    def self.get(config : Config, args : Array(String))
      Output.require_auth!(config)
      Output.require_args!(args, 2, "dust get <store> <path>")

      store, path = args[0], args[1]

      # For get, we join the store (catching up), then read from cache
      conn = Connection.new(config)
      conn.connect
      channel = conn.join(store)

      # Wait briefly for catch-up, then read from cache
      cache = Cache.new
      result = cache.read(store, path)

      if result
        Output.json(result)
      else
        Output.error("Not found: #{store}/#{path}")
      end

      conn.close
    end

    def self.merge(config : Config, args : Array(String))
      Output.require_auth!(config)
      Output.require_args!(args, 3, "dust merge <store> <path> <json>")

      store, path, value_str = args[0], args[1], args[2]
      value = JSON.parse(value_str)

      conn = Connection.new(config)
      conn.connect
      channel = conn.join(store)

      reply = channel.push("write", {
        "op" => "merge",
        "path" => path,
        "value" => value,
        "client_op_id" => "cli_#{Random::Secure.hex(8)}"
      })

      Output.success("Merged #{store}/#{path} (seq: #{reply["store_seq"]})")
      conn.close
    end

    def self.delete(config : Config, args : Array(String))
      Output.require_auth!(config)
      Output.require_args!(args, 2, "dust delete <store> <path>")

      store, path = args[0], args[1]

      conn = Connection.new(config)
      conn.connect
      channel = conn.join(store)

      reply = channel.push("write", {
        "op" => "delete",
        "path" => path,
        "value" => nil,
        "client_op_id" => "cli_#{Random::Secure.hex(8)}"
      })

      Output.success("Deleted #{store}/#{path} (seq: #{reply["store_seq"]})")
      conn.close
    end

    def self.enum(config : Config, args : Array(String))
      Output.require_auth!(config)
      Output.require_args!(args, 2, "dust enum <store> <pattern>")

      store, pattern = args[0], args[1]

      # Join store to catch up, then read from cache
      conn = Connection.new(config)
      conn.connect
      conn.join(store)

      # Read all entries from cache and filter by glob
      cache = Cache.new
      # TODO: glob matching in cache query
      Output.json([] of JSON::Any)
      conn.close
    end
  end
end
```

### Step 3: Implement auth commands

`cli/src/dust/commands/auth.cr`:

```crystal
module Dust::Commands
  module Auth
    def self.login(config : Config)
      puts "Enter your Dust API token:"
      print "> "
      token = gets.try(&.strip) || ""

      if token.empty?
        Output.error("Token cannot be empty")
      end

      config.save_credentials(token)
      Output.success("Authenticated successfully. Token saved to #{Config::CREDENTIALS_FILE}")
    end

    def self.logout(config : Config)
      if File.exists?(Config::CREDENTIALS_FILE)
        File.delete(Config::CREDENTIALS_FILE)
        Output.success("Logged out. Credentials removed.")
      else
        puts "Not currently logged in."
      end
    end
  end
end
```

### Step 4: Implement store commands

`cli/src/dust/commands/store.cr`:

```crystal
module Dust::Commands
  module Store
    def self.create(config : Config, args : Array(String))
      Output.require_auth!(config)
      Output.require_args!(args, 1, "dust create <store>")
      # TODO: REST API call to create store
      Output.success("Store creation requires the web dashboard for now.")
    end

    def self.list(config : Config)
      Output.require_auth!(config)
      # TODO: REST API call to list stores
      puts "Store listing requires the web dashboard for now."
    end

    def self.status(config : Config, args : Array(String))
      Output.require_auth!(config)
      puts "Status: #{config.authenticated? ? "authenticated" : "not authenticated"}"
      puts "Server: #{config.server_url}"
      puts "Device: #{config.device_id}"
    end
  end
end
```

### Step 5: Build and test manually

```bash
cd cli && crystal build src/dust.cr -o dust
./dust --version
./dust help
./dust status
```

### Step 6: Commit

```bash
git add cli/
git commit -m "feat: add core CLI commands — put, get, merge, delete, enum, auth"
```

---

## Task 10: Crystal CLI — Extended Commands

Add type commands (increment, add, remove), file commands, watch, log, rollback, and token management.

**Files:**
- Create: `cli/src/dust/commands/types.cr`
- Create: `cli/src/dust/commands/files.cr`
- Create: `cli/src/dust/commands/watch.cr`
- Create: `cli/src/dust/commands/log.cr`
- Create: `cli/src/dust/commands/token.cr`

### Step 1: Type commands

`increment`, `add`, `remove` — same pattern as `put` but with different ops.

### Step 2: Watch command

`cli/src/dust/commands/watch.cr`:
- Join store channel
- Register for events matching the pattern
- Print each event as a JSON line to stdout
- Run until interrupted (SIGINT)

### Step 3: File commands

`put-file` reads file from disk, base64-encodes, sends via `put_file` channel message.
`fetch-file` gets the file reference, then HTTP GETs the blob from `/api/files/:hash`.

### Step 4: Log and rollback

`log` — REST API or channel query for audit log.
`rollback` — channel `rollback` message.

### Step 5: Token commands

`token create/list/revoke` — REST API calls.

### Step 6: Build and test

```bash
cd cli && crystal build src/dust.cr -o dust
./dust put test/store posts.hello '{"title":"Hello"}'
./dust get test/store posts.hello
```

### Step 7: Commit

```bash
git add cli/
git commit -m "feat: add extended CLI commands — types, files, watch, log, rollback, tokens"
```

---

## Task 11: Integration Testing

End-to-end test: Crystal CLI talks to the real Dust server.

**Files:**
- Create: `cli/spec/integration_spec.cr`
- Create: `cli/spec/support/server_helper.cr`

### Step 1: Write integration tests

These tests assume the Dust server is running on localhost:7755 with a test token.

```crystal
describe "Integration" do
  it "put and get round-trip" do
    # Use Process.run to call the CLI binary
    # dust put test/store key '{"hello":"world"}'
    # dust get test/store key
    # Assert output matches
  end

  it "watch receives events" do
    # Start watch in background
    # Put a value from another process
    # Assert watch output contains the event
  end
end
```

### Step 2: Commit

```bash
git add cli/
git commit -m "feat: add CLI integration tests against real Dust server"
```

---

## Task Summary

| Task | Description | Depends on |
|------|-------------|------------|
| 1 | `use Dust` facade module | — |
| 2 | Declarative subscribers | 1 |
| 3 | Test harness (seed/emit/set_status) | 1 |
| 4 | PubSub bridge | 1 |
| 5 | Igniter installer | 1 |
| 6 | Crystal CLI — project setup + config | — |
| 7 | Crystal CLI — Phoenix Channel client | 6 |
| 8 | Crystal CLI — SQLite cache | 6 |
| 9 | Crystal CLI — core commands | 7, 8 |
| 10 | Crystal CLI — extended commands | 9 |
| 11 | Integration testing | 9 |

**Parallelizable:** Tasks 1-5 (SDK) and Tasks 6-8 (CLI setup) are fully independent. Task 9 depends on 7+8. Tasks 2-5 all depend on 1 but are independent of each other.

**Recommended execution order:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11
