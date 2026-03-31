defmodule Dust.SyncEngineTest do
  use ExUnit.Case

  alias Dust.SyncEngine

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} = SyncEngine.start_link(
      store: "test/store",
      cache: {Dust.Cache.Memory, []}
    )

    :ok
  end

  test "put and get" do
    :ok = SyncEngine.put("test/store", "posts.hello", %{"title" => "Hello"})
    assert {:ok, %{"title" => "Hello"}} = SyncEngine.get("test/store", "posts.hello")
  end

  test "delete" do
    SyncEngine.put("test/store", "x", "value")
    SyncEngine.delete("test/store", "x")
    assert :miss = SyncEngine.get("test/store", "x")
  end

  test "merge updates children" do
    SyncEngine.put("test/store", "settings.theme", "light")
    SyncEngine.merge("test/store", "settings", %{"theme" => "dark", "locale" => "en"})
    assert {:ok, "dark"} = SyncEngine.get("test/store", "settings.theme")
    assert {:ok, "en"} = SyncEngine.get("test/store", "settings.locale")
  end

  test "enum returns matching entries" do
    SyncEngine.put("test/store", "posts.a", "1")
    SyncEngine.put("test/store", "posts.b", "2")
    SyncEngine.put("test/store", "config.x", "3")

    results = SyncEngine.enum("test/store", "posts.*")
    assert length(results) == 2
  end

  test "on fires callback for matching writes" do
    test_pid = self()
    SyncEngine.on("test/store", "posts.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "posts.hello", "value")
    assert_receive {:event, %{path: "posts.hello", committed: false, source: :local}}, 500
  end

  test "on does not fire for non-matching writes" do
    test_pid = self()
    SyncEngine.on("test/store", "posts.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "config.x", "value")
    refute_receive {:event, _}
  end

  test "status reports state" do
    status = SyncEngine.status("test/store")
    assert status.connection == :disconnected
    assert status.last_store_seq == 0
    assert status.pending_ops >= 0
  end

  test "works with Ecto cache adapter (module target)" do
    {:ok, _pid} =
      SyncEngine.start_link(
        store: "ecto/store",
        cache: {Dust.Cache.Ecto, Dust.TestRepo}
      )

    :ok = SyncEngine.put("ecto/store", "key", "value")
    assert {:ok, "value"} = SyncEngine.get("ecto/store", "key")
  end

  # Counter tests

  test "increment creates counter from nothing" do
    :ok = SyncEngine.increment("test/store", "stats.views", 5)
    assert {:ok, 5} = SyncEngine.get("test/store", "stats.views")
  end

  test "increment accumulates" do
    :ok = SyncEngine.increment("test/store", "stats.views", 3)
    :ok = SyncEngine.increment("test/store", "stats.views", 7)
    assert {:ok, 10} = SyncEngine.get("test/store", "stats.views")
  end

  test "increment defaults to 1" do
    :ok = SyncEngine.increment("test/store", "counter.default")
    assert {:ok, 1} = SyncEngine.get("test/store", "counter.default")
  end

  test "increment by negative (decrement)" do
    :ok = SyncEngine.increment("test/store", "stats.views", 10)
    :ok = SyncEngine.increment("test/store", "stats.views", -3)
    assert {:ok, 7} = SyncEngine.get("test/store", "stats.views")
  end

  test "increment fires callback" do
    test_pid = self()
    SyncEngine.on("test/store", "stats.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.increment("test/store", "stats.views", 5)
    assert_receive {:event, %{path: "stats.views", op: :increment, value: 5, committed: false}}, 500
  end

  # Set tests

  test "add creates set from nothing" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    assert {:ok, ["elixir"]} = SyncEngine.get("test/store", "post.tags")
  end

  test "add is idempotent" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    assert {:ok, ["elixir"]} = SyncEngine.get("test/store", "post.tags")
  end

  test "add multiple members" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    :ok = SyncEngine.add("test/store", "post.tags", "rust")
    {:ok, tags} = SyncEngine.get("test/store", "post.tags")
    assert "elixir" in tags
    assert "rust" in tags
  end

  test "remove deletes member" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    :ok = SyncEngine.add("test/store", "post.tags", "rust")
    :ok = SyncEngine.remove("test/store", "post.tags", "elixir")
    assert {:ok, ["rust"]} = SyncEngine.get("test/store", "post.tags")
  end

  test "remove from nonexistent set" do
    :ok = SyncEngine.remove("test/store", "post.tags", "elixir")
    assert {:ok, []} = SyncEngine.get("test/store", "post.tags")
  end

  test "add fires callback" do
    test_pid = self()
    SyncEngine.on("test/store", "post.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.add("test/store", "post.tags", "elixir")
    assert_receive {:event, %{path: "post.tags", op: :add, value: "elixir", committed: false}}, 500
  end

  test "remove fires callback" do
    test_pid = self()
    SyncEngine.add("test/store", "post.tags", "elixir")
    SyncEngine.on("test/store", "post.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.remove("test/store", "post.tags", "elixir")
    assert_receive {:event, %{path: "post.tags", op: :remove, value: "elixir", committed: false}}, 500
  end
end
