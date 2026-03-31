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
end
