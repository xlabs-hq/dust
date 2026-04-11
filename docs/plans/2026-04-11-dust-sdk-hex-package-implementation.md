# Dust SDK Hex Package + LiveDashboard Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the Elixir SDK from a path-dep monorepo library into a publishable hex package with inlined protocol, compile-guarded optional integrations, and a LiveDashboard page plugin.

**Architecture:** Protocol modules move from `DustProtocol.*` to `Dust.Protocol.*` inside the SDK. Optional-dep modules (Ecto, PubSub, LiveDashboard) wrap in `Code.ensure_loaded?` guards. New `Dust.ActivityBuffer` ETS ring buffer feeds the dashboard. Cache behaviour gains `count/2` and `browse/4` for paginated entry inspection. Connection gains `info/1` for status introspection.

**Tech Stack:** Elixir 1.17+, Phoenix LiveDashboard (optional), Ecto (optional), Phoenix PubSub (optional), Slipstream, ETS

**Reference docs:**
- Design: `docs/plans/2026-04-11-dust-sdk-hex-package-design.md`
- Protocol source: `protocol/elixir/lib/dust_protocol/`
- SDK source: `sdk/elixir/`

---

## Task 1: Inline Protocol Modules

Copy the 5 protocol modules into the SDK under `Dust.Protocol.*` namespace, update all references, remove the `dust_protocol` path dependency.

**Files:**
- Create: `sdk/elixir/lib/dust/protocol.ex`
- Create: `sdk/elixir/lib/dust/protocol/codec.ex`
- Create: `sdk/elixir/lib/dust/protocol/glob.ex`
- Create: `sdk/elixir/lib/dust/protocol/message.ex`
- Create: `sdk/elixir/lib/dust/protocol/op.ex`
- Create: `sdk/elixir/lib/dust/protocol/path.ex`
- Modify: `sdk/elixir/lib/dust/callback_registry.ex` (2 references)
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex` (2 references)
- Modify: `sdk/elixir/lib/dust/cache/memory.ex` (2 references)
- Modify: `sdk/elixir/mix.exs` (remove `dust_protocol` dep)

### Step 1: Create `Dust.Protocol` root module

`sdk/elixir/lib/dust/protocol.ex`:

```elixir
defmodule Dust.Protocol do
  @moduledoc "Shared wire protocol types for Dust SDKs."

  @current_capver 1
  @min_capver 1

  def current_capver, do: @current_capver
  def min_capver, do: @min_capver
end
```

### Step 2: Create the 5 protocol submodules

Copy each file from `protocol/elixir/lib/dust_protocol/`, changing `DustProtocol` to `Dust.Protocol` in the module name only.

`sdk/elixir/lib/dust/protocol/codec.ex` — copy `protocol/elixir/lib/dust_protocol/codec.ex`, rename `DustProtocol.Codec` → `Dust.Protocol.Codec`.

`sdk/elixir/lib/dust/protocol/glob.ex` — copy `protocol/elixir/lib/dust_protocol/glob.ex`, rename `DustProtocol.Glob` → `Dust.Protocol.Glob`.

`sdk/elixir/lib/dust/protocol/message.ex` — copy `protocol/elixir/lib/dust_protocol/message.ex`, rename `DustProtocol.Message` → `Dust.Protocol.Message`.

`sdk/elixir/lib/dust/protocol/op.ex` — copy `protocol/elixir/lib/dust_protocol/op.ex`, rename `DustProtocol.Op` → `Dust.Protocol.Op`.

`sdk/elixir/lib/dust/protocol/path.ex` — copy `protocol/elixir/lib/dust_protocol/path.ex`, rename `DustProtocol.Path` → `Dust.Protocol.Path`.

### Step 3: Update all SDK references from `DustProtocol` to `Dust.Protocol`

6 call sites need updating:

`sdk/elixir/lib/dust/callback_registry.ex:24`:
```elixir
# Old
compiled = DustProtocol.Glob.compile(pattern)
# New
compiled = Dust.Protocol.Glob.compile(pattern)
```

`sdk/elixir/lib/dust/callback_registry.ex:61`:
```elixir
# Old
DustProtocol.Glob.match?(compiled, path_segments)
# New
Dust.Protocol.Glob.match?(compiled, path_segments)
```

`sdk/elixir/lib/dust/cache/ecto.ex:26`:
```elixir
# Old
compiled = DustProtocol.Glob.compile(pattern)
# New
compiled = Dust.Protocol.Glob.compile(pattern)
```

`sdk/elixir/lib/dust/cache/ecto.ex:36`:
```elixir
# Old
DustProtocol.Glob.match?(compiled, String.split(path, "."))
# New
Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
```

`sdk/elixir/lib/dust/cache/memory.ex:59`:
```elixir
# Old
compiled = DustProtocol.Glob.compile(pattern)
# New
compiled = Dust.Protocol.Glob.compile(pattern)
```

`sdk/elixir/lib/dust/cache/memory.ex:64`:
```elixir
# Old
s == store and DustProtocol.Glob.match?(compiled, String.split(path, "."))
# New
s == store and Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
```

### Step 4: Remove `dust_protocol` dependency from mix.exs

`sdk/elixir/mix.exs` — remove `{:dust_protocol, path: "../../protocol/elixir"}` from deps.

### Step 5: Run tests to verify

Run: `cd sdk/elixir && mix test`
Expected: All existing tests pass.

### Step 6: Commit

```
git add sdk/elixir/lib/dust/protocol.ex sdk/elixir/lib/dust/protocol/ sdk/elixir/lib/dust/callback_registry.ex sdk/elixir/lib/dust/cache/ecto.ex sdk/elixir/lib/dust/cache/memory.ex sdk/elixir/mix.exs
git commit -m "feat(sdk): inline protocol modules as Dust.Protocol.*"
```

---

## Task 2: Compile-Guard Optional-Dep Modules

Wrap Ecto, PubSub, and mix task modules in `Code.ensure_loaded?` guards so they only compile when their deps are present.

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Modify: `sdk/elixir/lib/dust/cache/ecto/cache_entry.ex`
- Modify: `sdk/elixir/lib/dust/cache/ecto/migration.ex`
- Modify: `sdk/elixir/lib/dust/pubsub_bridge.ex`
- Modify: `sdk/elixir/lib/dust/subscriber.ex`
- Modify: `sdk/elixir/lib/dust/subscriber_registrar.ex`
- Modify: `sdk/elixir/lib/mix/tasks/dust.gen.migration.ex`
- Modify: `sdk/elixir/lib/mix/tasks/dust.install.ex`

### Step 1: Wrap Ecto modules

`sdk/elixir/lib/dust/cache/ecto.ex` — wrap entire module:

```elixir
if Code.ensure_loaded?(Ecto.Query) do
  defmodule Dust.Cache.Ecto do
    # ... existing module body unchanged ...
  end
end
```

`sdk/elixir/lib/dust/cache/ecto/cache_entry.ex` — wrap:

```elixir
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Dust.Cache.Ecto.CacheEntry do
    # ... existing module body unchanged ...
  end
end
```

`sdk/elixir/lib/dust/cache/ecto/migration.ex` — wrap:

```elixir
if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Dust.Cache.Ecto.Migration do
    # ... existing module body unchanged ...
  end
end
```

### Step 2: Wrap PubSub modules

`sdk/elixir/lib/dust/pubsub_bridge.ex` — wrap:

```elixir
if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Dust.PubSubBridge do
    # ... existing module body unchanged ...
  end
end
```

`sdk/elixir/lib/dust/subscriber.ex` — this module doesn't actually use Phoenix.PubSub directly. It only depends on `Dust.SyncEngine.on/4`. Leave it unwrapped — it's core functionality, not optional.

`sdk/elixir/lib/dust/subscriber_registrar.ex` — references `Dust.PubSubBridge` but only conditionally (`if pubsub do`). The `PubSubBridge` module may not exist, but the `if` guard means it's only called when pubsub is configured. Wrap the PubSub call in a function_exported? check:

```elixir
defmodule Dust.SubscriberRegistrar do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    subscribers = Keyword.get(opts, :subscribers, [])

    Enum.each(subscribers, fn subscriber_module ->
      subscriber_module.__dust_register__()
    end)

    pubsub = Keyword.get(opts, :pubsub)
    stores = Keyword.get(opts, :stores, [])

    if pubsub and Code.ensure_loaded?(Dust.PubSubBridge) do
      Dust.PubSubBridge.register(pubsub, stores)
    end

    :ignore
  end
end
```

### Step 3: Wrap mix tasks

`sdk/elixir/lib/mix/tasks/dust.gen.migration.ex` — wrap:

```elixir
if Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.Dust.Gen.Migration do
    # ... existing module body unchanged ...
  end
end
```

`sdk/elixir/lib/mix/tasks/dust.install.ex` — this task doesn't import Ecto directly. It calls `Mix.Task.run("dust.gen.migration")` which will fail gracefully if that task doesn't exist. Leave it unwrapped.

### Step 4: Run tests to verify

Run: `cd sdk/elixir && mix test`
Expected: All existing tests pass (test env has ecto_sql installed).

### Step 5: Commit

```
git add sdk/elixir/lib/dust/cache/ecto.ex sdk/elixir/lib/dust/cache/ecto/cache_entry.ex sdk/elixir/lib/dust/cache/ecto/migration.ex sdk/elixir/lib/dust/pubsub_bridge.ex sdk/elixir/lib/dust/subscriber_registrar.ex sdk/elixir/lib/mix/tasks/dust.gen.migration.ex
git commit -m "feat(sdk): compile-guard optional-dep modules with Code.ensure_loaded?"
```

---

## Task 3: Add `count/2` and `browse/4` to Cache Behaviour

Add two new callbacks for dashboard introspection. Implement in both Memory and Ecto adapters.

**Files:**
- Modify: `sdk/elixir/lib/dust/cache.ex`
- Modify: `sdk/elixir/lib/dust/cache/memory.ex`
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Test: `sdk/elixir/test/dust/cache/memory_browse_test.exs`
- Test: `sdk/elixir/test/dust/cache/ecto_browse_test.exs`

### Step 1: Write failing test for Memory adapter browse

Create `sdk/elixir/test/dust/cache/memory_browse_test.exs`:

```elixir
defmodule Dust.Cache.MemoryBrowseTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, pid} = Dust.Cache.Memory.start_link([])
    store = "test/store"

    # Seed 10 entries
    for i <- 1..10 do
      path = "items.item_#{String.pad_leading(to_string(i), 2, "0")}"
      Dust.Cache.Memory.write(pid, store, path, "value_#{i}", "string", i)
    end

    %{pid: pid, store: store}
  end

  test "count/2 returns number of entries", %{pid: pid, store: store} do
    assert Dust.Cache.Memory.count(pid, store) == 10
  end

  test "count/2 returns 0 for empty store", %{pid: pid} do
    assert Dust.Cache.Memory.count(pid, "empty/store") == 0
  end

  test "browse/4 returns first page", %{pid: pid, store: store} do
    {entries, cursor} = Dust.Cache.Memory.browse(pid, store, limit: 3)
    assert length(entries) == 3
    assert cursor != nil

    # Entries are {path, value, type, seq} tuples sorted by path
    [{path1, _, _, _} | _] = entries
    assert path1 == "items.item_01"
  end

  test "browse/4 paginates through all entries", %{pid: pid, store: store} do
    {page1, cursor1} = Dust.Cache.Memory.browse(pid, store, limit: 4)
    assert length(page1) == 4

    {page2, cursor2} = Dust.Cache.Memory.browse(pid, store, limit: 4, cursor: cursor1)
    assert length(page2) == 4

    {page3, cursor3} = Dust.Cache.Memory.browse(pid, store, limit: 4, cursor: cursor2)
    assert length(page3) == 2
    assert cursor3 == nil

    # No duplicates
    all_paths = Enum.map(page1 ++ page2 ++ page3, fn {path, _, _, _} -> path end)
    assert length(Enum.uniq(all_paths)) == 10
  end

  test "browse/4 filters by glob pattern", %{pid: pid, store: store} do
    # Add some entries outside the pattern
    Dust.Cache.Memory.write(pid, store, "other.thing", "x", "string", 11)

    {entries, _} = Dust.Cache.Memory.browse(pid, store, pattern: "items.*", limit: 100)
    assert length(entries) == 10
  end

  test "browse/4 with no options returns all sorted by path", %{pid: pid, store: store} do
    {entries, nil} = Dust.Cache.Memory.browse(pid, store, [])
    assert length(entries) == 10
    paths = Enum.map(entries, fn {path, _, _, _} -> path end)
    assert paths == Enum.sort(paths)
  end
end
```

### Step 2: Run test to verify it fails

Run: `cd sdk/elixir && mix test test/dust/cache/memory_browse_test.exs`
Expected: FAIL — `count/2` and `browse/4` not defined.

### Step 3: Add callbacks to Cache behaviour

`sdk/elixir/lib/dust/cache.ex` — add two new callbacks:

```elixir
defmodule Dust.Cache do
  @callback read(target :: term(), store :: String.t(), path :: String.t()) :: {:ok, term()} | :miss
  @callback read_all(target :: term(), store :: String.t(), pattern :: String.t()) :: [{String.t(), term()}]
  @callback write(target :: term(), store :: String.t(), path :: String.t(), value :: term(), type :: String.t(), seq :: integer()) :: :ok
  @callback write_batch(target :: term(), store :: String.t(), entries :: list()) :: :ok
  @callback delete(target :: term(), store :: String.t(), path :: String.t()) :: :ok
  @callback last_seq(target :: term(), store :: String.t()) :: integer()
  @callback count(target :: term(), store :: String.t()) :: non_neg_integer()
  @callback browse(target :: term(), store :: String.t(), opts :: keyword()) ::
              {[{String.t(), term(), String.t(), integer()}], term() | nil}

  @optional_callbacks [count: 2, browse: 3]
end
```

Mark `count` and `browse` as `@optional_callbacks` so existing custom adapters don't break.

### Step 4: Implement in Memory adapter

Add to `sdk/elixir/lib/dust/cache/memory.ex` — two new `@impl` functions and their `handle_call` clauses:

```elixir
@impl Dust.Cache
def count(pid, store) do
  GenServer.call(pid, {:count, store})
end

@impl Dust.Cache
def browse(pid, store, opts) do
  GenServer.call(pid, {:browse, store, opts})
end
```

And the handle_call implementations:

```elixir
@impl true
def handle_call({:count, store}, _from, state) do
  count =
    state.entries
    |> Enum.count(fn {{s, _path}, _} -> s == store end)

  {:reply, count, state}
end

@impl true
def handle_call({:browse, store, opts}, _from, state) do
  pattern = Keyword.get(opts, :pattern, "**")
  cursor = Keyword.get(opts, :cursor)
  limit = Keyword.get(opts, :limit, 50)

  compiled = Dust.Protocol.Glob.compile(pattern)

  entries =
    state.entries
    |> Enum.filter(fn {{s, path}, _} ->
      s == store and Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
    end)
    |> Enum.map(fn {{_s, path}, {value, type, seq}} -> {path, value, type, seq} end)
    |> Enum.sort_by(fn {path, _, _, _} -> path end)

  # Apply cursor (keyset: path > cursor)
  entries =
    if cursor do
      Enum.drop_while(entries, fn {path, _, _, _} -> path <= cursor end)
    else
      entries
    end

  # Apply limit
  page = Enum.take(entries, limit)
  next_cursor =
    if length(page) < limit or length(page) == 0 do
      nil
    else
      {last_path, _, _, _} = List.last(page)
      last_path
    end

  {:reply, {page, next_cursor}, state}
end
```

### Step 5: Run test to verify it passes

Run: `cd sdk/elixir && mix test test/dust/cache/memory_browse_test.exs`
Expected: All tests pass.

### Step 6: Write failing test for Ecto adapter browse

Create `sdk/elixir/test/dust/cache/ecto_browse_test.exs`:

```elixir
defmodule Dust.Cache.EctoBrowseTest do
  use ExUnit.Case

  alias Dust.Cache.Ecto, as: EctoCache

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dust.TestRepo)
    store = "test/browse_store"

    for i <- 1..10 do
      path = "items.item_#{String.pad_leading(to_string(i), 2, "0")}"
      EctoCache.write(Dust.TestRepo, store, path, "value_#{i}", "string", i)
    end

    %{store: store}
  end

  test "count/2 returns entry count excluding sentinel", %{store: store} do
    assert EctoCache.count(Dust.TestRepo, store) == 10
  end

  test "browse/4 paginates with keyset cursor", %{store: store} do
    {page1, cursor1} = EctoCache.browse(Dust.TestRepo, store, limit: 4)
    assert length(page1) == 4

    {page2, cursor2} = EctoCache.browse(Dust.TestRepo, store, limit: 4, cursor: cursor1)
    assert length(page2) == 4

    {page3, cursor3} = EctoCache.browse(Dust.TestRepo, store, limit: 4, cursor: cursor2)
    assert length(page3) == 2
    assert cursor3 == nil

    all_paths = Enum.map(page1 ++ page2 ++ page3, fn {path, _, _, _} -> path end)
    assert length(Enum.uniq(all_paths)) == 10
  end

  test "browse/4 filters by glob pattern", %{store: store} do
    EctoCache.write(Dust.TestRepo, store, "other.thing", "x", "string", 11)

    {entries, _} = EctoCache.browse(Dust.TestRepo, store, pattern: "items.*", limit: 100)
    assert length(entries) == 10
  end
end
```

### Step 7: Run test to verify it fails

Run: `cd sdk/elixir && mix test test/dust/cache/ecto_browse_test.exs`
Expected: FAIL — `count/2` and `browse/4` not defined on Ecto adapter.

### Step 8: Implement in Ecto adapter

Add to `sdk/elixir/lib/dust/cache/ecto.ex` (inside the `Code.ensure_loaded?` guard):

```elixir
@impl Dust.Cache
def count(repo, store) do
  query =
    from(c in CacheEntry,
      where: c.store == ^store and c.path != ^@seq_sentinel_path,
      select: count()
    )

  repo.one(query)
end

@impl Dust.Cache
def browse(repo, store, opts) do
  pattern = Keyword.get(opts, :pattern, "**")
  cursor = Keyword.get(opts, :cursor)
  limit = Keyword.get(opts, :limit, 50)

  compiled = Dust.Protocol.Glob.compile(pattern)

  query =
    from(c in CacheEntry,
      where: c.store == ^store and c.path != ^@seq_sentinel_path,
      order_by: [asc: c.path],
      limit: ^(limit + 1),
      select: {c.path, c.value, c.type, c.seq}
    )

  query =
    if cursor do
      from(c in query, where: c.path > ^cursor)
    else
      query
    end

  rows = repo.all(query)

  # Post-filter by glob pattern (only when pattern is not "**")
  filtered =
    if pattern == "**" do
      rows
    else
      Enum.filter(rows, fn {path, _, _, _} ->
        Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
      end)
    end

  # Decode JSON values
  decoded =
    Enum.map(filtered, fn {path, json, type, seq} ->
      {path, Jason.decode!(json), type, seq}
    end)

  # Determine pagination
  page = Enum.take(decoded, limit)
  next_cursor =
    if length(decoded) > limit do
      {last_path, _, _, _} = List.last(page)
      last_path
    else
      nil
    end

  {page, next_cursor}
end
```

### Step 9: Run test to verify it passes

Run: `cd sdk/elixir && mix test test/dust/cache/ecto_browse_test.exs`
Expected: All tests pass.

### Step 10: Run full test suite

Run: `cd sdk/elixir && mix test`
Expected: All tests pass.

### Step 11: Commit

```
git add sdk/elixir/lib/dust/cache.ex sdk/elixir/lib/dust/cache/memory.ex sdk/elixir/lib/dust/cache/ecto.ex sdk/elixir/test/dust/cache/
git commit -m "feat(sdk): add count/2 and browse/4 to Cache behaviour"
```

---

## Task 4: Add Connection Introspection

Add `info/1` to `Dust.Connection` and extend `Dust.SyncEngine.status/1` with entry count.

**Files:**
- Modify: `sdk/elixir/lib/dust/connection.ex`
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Test: `sdk/elixir/test/dust/connection_info_test.exs`

### Step 1: Write failing test for Connection.info

Create `sdk/elixir/test/dust/connection_info_test.exs`:

```elixir
defmodule Dust.ConnectionInfoTest do
  use ExUnit.Case, async: true

  test "info/1 returns connection metadata" do
    opts = [
      url: "ws://localhost:7755/ws/sync",
      token: "test_token",
      device_id: "dev_test123",
      stores: ["test/store"],
      test_mode?: true,
      name: :"conn_info_test_#{System.unique_integer()}"
    ]

    {:ok, pid} = Dust.Connection.start_link(opts)

    info = Dust.Connection.info(pid)
    assert info.url == "ws://localhost:7755/ws/sync"
    assert info.device_id == "dev_test123"
    assert info.status == :disconnected
    assert info.connected_at == nil
  end
end
```

### Step 2: Run test to verify it fails

Run: `cd sdk/elixir && mix test test/dust/connection_info_test.exs`
Expected: FAIL — `info/1` not defined.

### Step 3: Implement Connection.info/1

Modify `sdk/elixir/lib/dust/connection.ex`:

Add public function:

```elixir
def info(pid) do
  GenServer.call(pid, :info)
end
```

In `init/1`, add assigns for `url` and `status`:

```elixir
socket =
  new_socket()
  |> assign(:token, token)
  |> assign(:device_id, device_id)
  |> assign(:stores, stores)
  |> assign(:joined_stores, MapSet.new())
  |> assign(:outbox, %{})
  |> assign(:pending_refs, %{})
  |> assign(:url, url)
  |> assign(:status, :disconnected)
  |> assign(:connected_at, nil)
```

In `handle_connect/1`, set connected_at and status:

```elixir
def handle_connect(socket) do
  Logger.info("[Dust.Connection] Connected to server")

  socket =
    socket
    |> assign(:status, :connected)
    |> assign(:connected_at, DateTime.utc_now())

  # ... rest of existing handle_connect
end
```

In `handle_disconnect/2`, update status:

```elixir
def handle_disconnect(reason, socket) do
  Logger.warning("[Dust.Connection] Disconnected: #{inspect(reason)}")

  socket = assign(socket, :status, :reconnecting)
  # ... rest of existing handle_disconnect
end
```

Add `handle_call` for `:info` — use Slipstream's `@impl Slipstream` for `handle_info`, but for GenServer calls, add:

```elixir
# Note: Slipstream processes support handle_call via GenServer
def handle_call(:info, _from, socket) do
  now = DateTime.utc_now()
  connected_at = socket.assigns.connected_at

  uptime_seconds =
    if connected_at do
      DateTime.diff(now, connected_at, :second)
    else
      nil
    end

  info = %{
    status: socket.assigns.status,
    url: socket.assigns.url,
    device_id: socket.assigns.device_id,
    connected_at: connected_at,
    uptime_seconds: uptime_seconds,
    stores: socket.assigns.stores,
    joined_stores: MapSet.to_list(socket.assigns.joined_stores)
  }

  {:reply, info, socket}
end
```

### Step 4: Extend SyncEngine.status/1

Modify `sdk/elixir/lib/dust/sync_engine.ex`, the `handle_call(:status, ...)` clause:

```elixir
@impl true
def handle_call(:status, _from, state) do
  entry_count =
    if function_exported?(state.cache, :count, 2) do
      state.cache.count(state.cache_target, state.store)
    else
      nil
    end

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

### Step 5: Run test to verify it passes

Run: `cd sdk/elixir && mix test test/dust/connection_info_test.exs`
Expected: PASS.

### Step 6: Run full test suite

Run: `cd sdk/elixir && mix test`
Expected: All tests pass.

### Step 7: Commit

```
git add sdk/elixir/lib/dust/connection.ex sdk/elixir/lib/dust/sync_engine.ex sdk/elixir/test/dust/connection_info_test.exs
git commit -m "feat(sdk): add Connection.info/1 and extend SyncEngine.status with entry_count"
```

---

## Task 5: Add Activity Buffer

ETS-backed circular buffer for recent operations. SyncEngine appends to it on each processed event.

**Files:**
- Create: `sdk/elixir/lib/dust/activity_buffer.ex`
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Modify: `sdk/elixir/lib/dust/supervisor.ex`
- Test: `sdk/elixir/test/dust/activity_buffer_test.exs`

### Step 1: Write failing test

Create `sdk/elixir/test/dust/activity_buffer_test.exs`:

```elixir
defmodule Dust.ActivityBufferTest do
  use ExUnit.Case, async: true

  setup do
    name = :"activity_buf_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Dust.ActivityBuffer.start_link(name: name)
    %{buf: name}
  end

  test "append and recent", %{buf: buf} do
    Dust.ActivityBuffer.append(buf, "test/store", %{
      path: "posts.hello",
      op: :set,
      source: :server,
      seq: 1
    })

    entries = Dust.ActivityBuffer.recent(buf, "test/store")
    assert length(entries) == 1
    assert hd(entries).path == "posts.hello"
    assert hd(entries).op == :set
    assert %DateTime{} = hd(entries).timestamp
  end

  test "recent returns newest first", %{buf: buf} do
    for i <- 1..5 do
      Dust.ActivityBuffer.append(buf, "test/store", %{
        path: "item.#{i}",
        op: :set,
        source: :server,
        seq: i
      })
    end

    entries = Dust.ActivityBuffer.recent(buf, "test/store")
    seqs = Enum.map(entries, & &1.seq)
    assert seqs == [5, 4, 3, 2, 1]
  end

  test "caps at 100 entries per store", %{buf: buf} do
    for i <- 1..150 do
      Dust.ActivityBuffer.append(buf, "test/store", %{
        path: "item.#{i}",
        op: :set,
        source: :server,
        seq: i
      })
    end

    entries = Dust.ActivityBuffer.recent(buf, "test/store")
    assert length(entries) == 100
    # Newest entries kept
    assert hd(entries).seq == 150
    assert List.last(entries).seq == 51
  end

  test "stores are independent", %{buf: buf} do
    Dust.ActivityBuffer.append(buf, "store/a", %{path: "x", op: :set, source: :local, seq: 1})
    Dust.ActivityBuffer.append(buf, "store/b", %{path: "y", op: :delete, source: :server, seq: 1})

    assert length(Dust.ActivityBuffer.recent(buf, "store/a")) == 1
    assert length(Dust.ActivityBuffer.recent(buf, "store/b")) == 1
    assert Dust.ActivityBuffer.recent(buf, "store/c") == []
  end

  test "recent with limit", %{buf: buf} do
    for i <- 1..10 do
      Dust.ActivityBuffer.append(buf, "test/store", %{path: "item.#{i}", op: :set, source: :server, seq: i})
    end

    entries = Dust.ActivityBuffer.recent(buf, "test/store", 3)
    assert length(entries) == 3
    assert hd(entries).seq == 10
  end
end
```

### Step 2: Run test to verify it fails

Run: `cd sdk/elixir && mix test test/dust/activity_buffer_test.exs`
Expected: FAIL — module not defined.

### Step 3: Implement ActivityBuffer

Create `sdk/elixir/lib/dust/activity_buffer.ex`:

```elixir
defmodule Dust.ActivityBuffer do
  @moduledoc """
  ETS-backed circular buffer for recent Dust operations.

  Stores the last 100 events per store for dashboard display.
  Append is a direct ETS write — no GenServer serialization on the hot path.
  """

  @max_entries 100

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(name, [:named_table, :public, :set])
    # Store the table ref under a known key for the supervisor
    :persistent_term.put({__MODULE__, name}, table)
    :ignore
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:name]},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  def append(name, store, attrs) do
    entry = Map.merge(attrs, %{
      timestamp: DateTime.utc_now(),
      store: store
    })

    # Get and increment the per-store index
    idx = :ets.update_counter(name, {:idx, store}, {2, 1}, {{:idx, store}, 0})
    slot = rem(idx - 1, @max_entries)

    :ets.insert(name, {{store, slot}, entry})
    :ok
  end

  def recent(name, store, limit \\ @max_entries) do
    # Read up to @max_entries slots for this store
    entries =
      for slot <- 0..(@max_entries - 1),
          [{_key, entry}] <- [:ets.lookup(name, {store, slot})],
          do: entry

    entries
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.take(limit)
  end
end
```

### Step 4: Run test to verify it passes

Run: `cd sdk/elixir && mix test test/dust/activity_buffer_test.exs`
Expected: All tests pass.

### Step 5: Wire ActivityBuffer into Supervisor

Modify `sdk/elixir/lib/dust/supervisor.ex` — add the ActivityBuffer as the first child, before SyncEngines:

In `init/1`, add after the registry_children setup:

```elixir
activity_name = Keyword.get(opts, :activity_buffer_name, Dust.ActivityBuffer)

activity_children = [
  {Dust.ActivityBuffer, name: activity_name}
]
```

Update the children list:

```elixir
children =
  registry_children ++
    activity_children ++
    engine_children ++
    connection_children ++
    subscriber_children
```

Pass the activity buffer name to SyncEngine opts:

```elixir
engine_children =
  Enum.map(stores, fn store ->
    {Dust.SyncEngine, store: store, cache: cache, activity_buffer: activity_name}
  end)
```

### Step 6: Wire SyncEngine to append activity

Modify `sdk/elixir/lib/dust/sync_engine.ex`:

In `init/1`, store the activity buffer name:

```elixir
activity_buffer = Keyword.get(opts, :activity_buffer)
```

Add `activity_buffer` to the struct `defstruct` and to the initial state.

In `handle_cast({:server_event, event}, state)`, after updating cache and before reconciling pending ops, append to activity buffer:

```elixir
if state.activity_buffer do
  Dust.ActivityBuffer.append(state.activity_buffer, state.store, %{
    path: path,
    op: op,
    source: (if was_pending, do: :local, else: :server),
    seq: store_seq
  })
end
```

Note: `was_pending` is already computed in the existing code. Move the activity append after that check.

### Step 7: Run full test suite

Run: `cd sdk/elixir && mix test`
Expected: All tests pass.

### Step 8: Commit

```
git add sdk/elixir/lib/dust/activity_buffer.ex sdk/elixir/lib/dust/supervisor.ex sdk/elixir/lib/dust/sync_engine.ex sdk/elixir/test/dust/activity_buffer_test.exs
git commit -m "feat(sdk): add ActivityBuffer ETS ring buffer for dashboard"
```

---

## Task 6: LiveDashboard Page Plugin

Implement `Dust.Dashboard` as a `Phoenix.LiveDashboard.PageBuilder`.

**Files:**
- Create: `sdk/elixir/lib/dust/dashboard.ex`
- Modify: `sdk/elixir/mix.exs` (add `phoenix_live_dashboard` optional dep)

### Step 1: Add dashboard dep to mix.exs

Modify `sdk/elixir/mix.exs` — add to deps:

```elixir
{:phoenix_live_dashboard, "~> 0.8", optional: true},
{:phoenix_live_view, "~> 1.0", optional: true}
```

### Step 2: Implement Dashboard module

Create `sdk/elixir/lib/dust/dashboard.ex`:

```elixir
if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Dust.Dashboard do
    @moduledoc """
    LiveDashboard page for Dust SDK introspection.

    ## Setup

        live_dashboard "/dev/dashboard",
          additional_pages: [
            dust: Dust.Dashboard
          ]
    """

    use Phoenix.LiveDashboard.PageBuilder

    @refresh_interval 2000

    @impl true
    def menu_link(_, _) do
      {:ok, "Dust"}
    end

    @impl true
    def mount(_params, session, socket) do
      if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

      socket =
        socket
        |> assign(:connection_info, fetch_connection_info())
        |> assign(:stores, fetch_stores())
        |> assign(:selected_store, nil)
        |> assign(:entries, [])
        |> assign(:entries_cursor, nil)
        |> assign(:entries_filter, "")
        |> assign(:activity, [])
        |> assign(:nav, session["nav"] || :stores)

      {:ok, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <!-- Connection Bar -->
        <div style="display: flex; gap: 24px; align-items: center; margin-bottom: 16px; padding: 12px; background: #f8f9fa; border-radius: 6px;">
          <div>
            <strong>Status:</strong>
            <span style={"color: #{status_color(@connection_info.status)}"}>
              <%= @connection_info.status %>
            </span>
          </div>
          <div><strong>URL:</strong> <%= @connection_info.url || "—" %></div>
          <div><strong>Device:</strong> <code><%= @connection_info.device_id || "—" %></code></div>
          <div :if={@connection_info.uptime_seconds}>
            <strong>Uptime:</strong> <%= format_uptime(@connection_info.uptime_seconds) %>
          </div>
        </div>

        <!-- Stores Table -->
        <h3 style="margin-bottom: 8px;">Stores</h3>
        <table style="width: 100%; border-collapse: collapse; margin-bottom: 24px;">
          <thead>
            <tr style="border-bottom: 2px solid #dee2e6;">
              <th style="text-align: left; padding: 8px;">Store</th>
              <th style="text-align: right; padding: 8px;">Entries</th>
              <th style="text-align: right; padding: 8px;">Last Seq</th>
              <th style="text-align: right; padding: 8px;">Pending</th>
              <th style="text-align: center; padding: 8px;">Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={store <- @stores}
                style={"cursor: pointer; #{if @selected_store == store.name, do: "background: #e8f4fd;", else: ""}"}
                phx-click="select_store"
                phx-value-store={store.name}
                phx-target={@myself}>
              <td style="padding: 8px;"><code><%= store.name %></code></td>
              <td style="text-align: right; padding: 8px;"><%= store.entry_count || "—" %></td>
              <td style="text-align: right; padding: 8px;"><%= store.last_store_seq %></td>
              <td style="text-align: right; padding: 8px;"><%= store.pending_ops %></td>
              <td style="text-align: center; padding: 8px;">
                <span style={"color: #{status_color(store.connection)}"}>
                  <%= store.connection %>
                </span>
              </td>
            </tr>
          </tbody>
        </table>

        <!-- Bottom panels (entries + activity) -->
        <div :if={@selected_store} style="display: grid; grid-template-columns: 1fr 1fr; gap: 24px;">
          <!-- Entries Browser -->
          <div>
            <h3 style="margin-bottom: 8px;">Entries — <code><%= @selected_store %></code></h3>
            <form phx-change="filter_entries" phx-target={@myself} style="margin-bottom: 8px;">
              <input name="pattern" value={@entries_filter} placeholder="Filter by glob pattern..." style="width: 100%; padding: 6px; border: 1px solid #ced4da; border-radius: 4px;" />
            </form>
            <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
              <thead>
                <tr style="border-bottom: 1px solid #dee2e6;">
                  <th style="text-align: left; padding: 4px;">Path</th>
                  <th style="text-align: left; padding: 4px;">Value</th>
                  <th style="text-align: left; padding: 4px;">Type</th>
                  <th style="text-align: right; padding: 4px;">Seq</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{path, value, type, seq} <- @entries} style="border-bottom: 1px solid #f0f0f0;">
                  <td style="padding: 4px;"><code><%= path %></code></td>
                  <td style="padding: 4px; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                    <%= truncate_value(value) %>
                  </td>
                  <td style="padding: 4px;"><%= type %></td>
                  <td style="text-align: right; padding: 4px;"><%= seq %></td>
                </tr>
              </tbody>
            </table>
            <div :if={@entries_cursor} style="margin-top: 8px;">
              <button phx-click="next_page" phx-target={@myself} style="padding: 4px 12px; border: 1px solid #ced4da; border-radius: 4px; background: white; cursor: pointer;">
                Next page →
              </button>
            </div>
          </div>

          <!-- Activity Feed -->
          <div>
            <h3 style="margin-bottom: 8px;">Activity</h3>
            <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
              <thead>
                <tr style="border-bottom: 1px solid #dee2e6;">
                  <th style="text-align: left; padding: 4px;">Time</th>
                  <th style="text-align: left; padding: 4px;">Path</th>
                  <th style="text-align: left; padding: 4px;">Op</th>
                  <th style="text-align: left; padding: 4px;">Source</th>
                  <th style="text-align: right; padding: 4px;">Seq</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @activity} style="border-bottom: 1px solid #f0f0f0;">
                  <td style="padding: 4px;"><%= format_time(entry.timestamp) %></td>
                  <td style="padding: 4px;"><code><%= entry.path %></code></td>
                  <td style="padding: 4px;"><%= entry.op %></td>
                  <td style="padding: 4px;"><%= entry.source %></td>
                  <td style="text-align: right; padding: 4px;"><%= entry.seq %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      """
    end

    @impl true
    def handle_event("select_store", %{"store" => store}, socket) do
      {entries, cursor} = browse_store(store, nil, "")

      socket =
        socket
        |> assign(:selected_store, store)
        |> assign(:entries, entries)
        |> assign(:entries_cursor, cursor)
        |> assign(:entries_filter, "")
        |> assign(:activity, fetch_activity(store))

      {:noreply, socket}
    end

    def handle_event("filter_entries", %{"pattern" => pattern}, socket) do
      store = socket.assigns.selected_store
      {entries, cursor} = browse_store(store, nil, pattern)

      socket =
        socket
        |> assign(:entries, entries)
        |> assign(:entries_cursor, cursor)
        |> assign(:entries_filter, pattern)

      {:noreply, socket}
    end

    def handle_event("next_page", _, socket) do
      store = socket.assigns.selected_store
      cursor = socket.assigns.entries_cursor
      pattern = socket.assigns.entries_filter
      {entries, next_cursor} = browse_store(store, cursor, pattern)

      socket =
        socket
        |> assign(:entries, entries)
        |> assign(:entries_cursor, next_cursor)

      {:noreply, socket}
    end

    @impl true
    def handle_info(:refresh, socket) do
      Process.send_after(self(), :refresh, @refresh_interval)

      socket =
        socket
        |> assign(:connection_info, fetch_connection_info())
        |> assign(:stores, fetch_stores())

      socket =
        if store = socket.assigns.selected_store do
          assign(socket, :activity, fetch_activity(store))
        else
          socket
        end

      {:noreply, socket}
    end

    # Data fetching

    defp fetch_connection_info do
      case GenServer.whereis(Dust.Connection) do
        nil -> %{status: :not_started, url: nil, device_id: nil, uptime_seconds: nil}
        pid -> Dust.Connection.info(pid)
      end
    end

    defp fetch_stores do
      Registry.select(Dust.SyncEngineRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {store, pid} ->
        try do
          GenServer.call(pid, :status, 1000)
        catch
          :exit, _ -> %{store: store, connection: :unknown, last_store_seq: 0, pending_ops: 0, entry_count: nil}
        end
      end)
      |> Enum.sort_by(& &1.store)
    end

    defp browse_store(store, cursor, pattern) do
      case Registry.lookup(Dust.SyncEngineRegistry, store) do
        [{pid, _}] ->
          %{cache: cache_mod, cache_target: target} = :sys.get_state(pid)

          if function_exported?(cache_mod, :browse, 3) do
            opts = [limit: 50, cursor: cursor]
            opts = if pattern != "", do: Keyword.put(opts, :pattern, pattern), else: opts
            cache_mod.browse(target, store, opts)
          else
            {[], nil}
          end

        [] ->
          {[], nil}
      end
    end

    defp fetch_activity(store) do
      if :ets.whereis(Dust.ActivityBuffer) != :undefined do
        Dust.ActivityBuffer.recent(Dust.ActivityBuffer, store, 50)
      else
        []
      end
    end

    # Formatting helpers

    defp status_color(:connected), do: "#28a745"
    defp status_color(:disconnected), do: "#dc3545"
    defp status_color(:reconnecting), do: "#ffc107"
    defp status_color(:not_started), do: "#6c757d"
    defp status_color(_), do: "#6c757d"

    defp format_uptime(nil), do: "—"
    defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
    defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
    defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

    defp format_time(%DateTime{} = dt) do
      Calendar.strftime(dt, "%H:%M:%S")
    end

    defp truncate_value(value) when is_binary(value) and byte_size(value) > 80 do
      String.slice(value, 0, 80) <> "…"
    end

    defp truncate_value(value) when is_map(value) or is_list(value) do
      inspected = inspect(value, limit: 5, printable_limit: 80)
      if String.length(inspected) > 80, do: String.slice(inspected, 0, 80) <> "…", else: inspected
    end

    defp truncate_value(value), do: inspect(value)
  end
end
```

### Step 3: Run SDK tests

Run: `cd sdk/elixir && mix deps.get && mix test`
Expected: All tests pass. Dashboard module compiles because LiveDashboard is available in test deps (add it if needed).

### Step 4: Commit

```
git add sdk/elixir/lib/dust/dashboard.ex sdk/elixir/mix.exs
git commit -m "feat(sdk): add LiveDashboard page plugin"
```

---

## Task 7: Hex Package Metadata

Add proper `package/0`, `docs/0`, and `description` to mix.exs.

**Files:**
- Modify: `sdk/elixir/mix.exs`

### Step 1: Update mix.exs

Replace the full mix.exs with hex-ready config:

```elixir
defmodule Dust.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jamestippett/dust"

  def project do
    [
      app: :dust,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      description: "Reactive global state for Elixir apps",
      source_url: @source_url,
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Core
      {:slipstream, "~> 1.2"},
      {:msgpax, "~> 2.4"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},
      {:req, "~> 0.5"},

      # Optional integrations
      {:phoenix_pubsub, "~> 2.0", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},

      # Dev/Test
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Dust",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
```

### Step 2: Run tests

Run: `cd sdk/elixir && mix deps.get && mix test`
Expected: All tests pass.

### Step 3: Commit

```
git add sdk/elixir/mix.exs
git commit -m "feat(sdk): add hex package metadata"
```

---

## Task 8: Protocol Compatibility Test Fixtures

Create shared test vectors that both the server's `DustProtocol` and the SDK's `Dust.Protocol` run against.

**Files:**
- Create: `protocol/spec/fixtures/glob_vectors.json`
- Create: `protocol/spec/fixtures/path_vectors.json`
- Create: `protocol/spec/fixtures/codec_vectors.json`
- Create: `sdk/elixir/test/dust/protocol/compatibility_test.exs`

### Step 1: Create test fixture files

`protocol/spec/fixtures/glob_vectors.json`:

```json
[
  {"pattern": "**", "path": ["a"], "match": true},
  {"pattern": "**", "path": ["a", "b", "c"], "match": true},
  {"pattern": "*", "path": ["a"], "match": true},
  {"pattern": "*", "path": ["a", "b"], "match": false},
  {"pattern": "posts.*", "path": ["posts", "hello"], "match": true},
  {"pattern": "posts.*", "path": ["posts", "hello", "title"], "match": false},
  {"pattern": "posts.**", "path": ["posts", "hello", "title"], "match": true},
  {"pattern": "a.b.c", "path": ["a", "b", "c"], "match": true},
  {"pattern": "a.b.c", "path": ["a", "b", "d"], "match": false},
  {"pattern": "a.*.c", "path": ["a", "b", "c"], "match": true},
  {"pattern": "a.*.c", "path": ["a", "b", "d"], "match": false}
]
```

`protocol/spec/fixtures/path_vectors.json`:

```json
[
  {"input": "a.b.c", "segments": ["a", "b", "c"], "valid": true},
  {"input": "hello", "segments": ["hello"], "valid": true},
  {"input": "", "valid": false, "error": "empty_path"},
  {"input": "a..b", "valid": false, "error": "empty_segment"},
  {"input": ".a", "valid": false, "error": "empty_segment"},
  {"input": "a.", "valid": false, "error": "empty_segment"}
]
```

`protocol/spec/fixtures/codec_vectors.json`:

```json
[
  {"format": "json", "input": {"key": "value"}, "roundtrip": true},
  {"format": "json", "input": {"nested": {"a": 1}}, "roundtrip": true},
  {"format": "msgpack", "input": {"key": "value"}, "roundtrip": true},
  {"format": "msgpack", "input": {"num": 42, "str": "hello"}, "roundtrip": true}
]
```

### Step 2: Write compatibility test for SDK

Create `sdk/elixir/test/dust/protocol/compatibility_test.exs`:

```elixir
defmodule Dust.Protocol.CompatibilityTest do
  use ExUnit.Case, async: true

  @fixtures_path Path.expand("../../../../protocol/spec/fixtures", __DIR__)

  describe "glob matching" do
    test "matches shared test vectors" do
      vectors = read_fixture("glob_vectors.json")

      for %{"pattern" => pattern, "path" => path, "match" => expected} <- vectors do
        result = Dust.Protocol.Glob.match?(pattern, path)
        assert result == expected,
          "Glob.match?(#{inspect(pattern)}, #{inspect(path)}) = #{result}, expected #{expected}"
      end
    end
  end

  describe "path parsing" do
    test "matches shared test vectors" do
      vectors = read_fixture("path_vectors.json")

      for vector <- vectors do
        case vector do
          %{"input" => input, "valid" => true, "segments" => segments} ->
            assert {:ok, ^segments} = Dust.Protocol.Path.parse(input)

          %{"input" => input, "valid" => false, "error" => error} ->
            assert {:error, err} = Dust.Protocol.Path.parse(input)
            assert to_string(err) == error
        end
      end
    end
  end

  describe "codec roundtrip" do
    test "matches shared test vectors" do
      vectors = read_fixture("codec_vectors.json")

      for %{"format" => format, "input" => input, "roundtrip" => true} <- vectors do
        format_atom = String.to_existing_atom(format)
        {:ok, encoded} = Dust.Protocol.Codec.encode(format_atom, input)
        {:ok, decoded} = Dust.Protocol.Codec.decode(format_atom, encoded)
        assert decoded == input,
          "Codec roundtrip failed for #{format}: #{inspect(input)}"
      end
    end
  end

  defp read_fixture(name) do
    @fixtures_path
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
```

### Step 3: Run tests

Run: `cd sdk/elixir && mix test test/dust/protocol/compatibility_test.exs`
Expected: All pass.

### Step 4: Commit

```
git add protocol/spec/fixtures/ sdk/elixir/test/dust/protocol/compatibility_test.exs
git commit -m "test(sdk): add shared protocol compatibility test fixtures"
```

---

## Summary

8 tasks, ordered for minimal rework:

1. **Inline protocol** — copy modules, update references, remove path dep
2. **Compile guards** — wrap optional-dep modules in `Code.ensure_loaded?`
3. **Cache browse API** — `count/2` and `browse/4` with keyset pagination
4. **Connection introspection** — `info/1` and extended `status/1`
5. **Activity buffer** — ETS ring buffer, wired into SyncEngine
6. **Dashboard plugin** — `Phoenix.LiveDashboard.PageBuilder` implementation
7. **Hex metadata** — `package/0`, `docs/0`, `ex_doc` dep
8. **Protocol compatibility** — shared fixtures, SDK test runner
