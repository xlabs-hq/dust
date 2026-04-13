defmodule DustTest do
  use ExUnit.Case

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} =
      Dust.SyncEngine.start_link(
        store: "test/store",
        cache: {Dust.Cache.Memory, []}
      )

    :ok
  end

  test "Dust.entry/2 delegates to SyncEngine" do
    :ok = Dust.SyncEngine.seed_entry("test/store", "a", 1, "integer")
    assert {:ok, %Dust.Entry{path: "a", value: 1, revision: _}} = Dust.entry("test/store", "a")
  end

  test "Dust.enum/3 returns a %Dust.Page{} with %Dust.Entry{} items" do
    :ok = Dust.SyncEngine.put("test/store", "posts.a", "1")
    :ok = Dust.SyncEngine.put("test/store", "posts.b", "2")

    page = Dust.enum("test/store", "posts.*", [])
    assert %Dust.Page{} = page
    assert length(page.items) == 2
    assert Enum.all?(page.items, &match?(%Dust.Entry{}, &1))
    paths = Enum.map(page.items, & &1.path) |> Enum.sort()
    assert paths == ["posts.a", "posts.b"]
  end

  test "Dust.enum/2 still returns the flat [{path, value}, ...] list" do
    :ok = Dust.SyncEngine.put("test/store", "posts.a", "1")
    :ok = Dust.SyncEngine.put("test/store", "posts.b", "2")

    results = Dust.enum("test/store", "posts.*")
    assert is_list(results)
    assert length(results) == 2
    assert Enum.all?(results, &match?({_path, _value}, &1))
  end

  test "Dust.range/4 delegates to SyncEngine" do
    :ok = Dust.SyncEngine.seed_entry("test/store", "a", 1, "integer")

    assert %Dust.Page{items: [%Dust.Entry{path: "a"}]} =
             Dust.range("test/store", "a", "z", limit: 10)
  end

  test "Dust.get_many/2 delegates to SyncEngine" do
    :ok = Dust.SyncEngine.put("test/store", "a", 1)
    :ok = Dust.SyncEngine.put("test/store", "b", 2)

    assert Dust.get_many("test/store", ["a", "b"]) == %{"a" => 1, "b" => 2}
  end

  test "Dust.watch/4 is an alias for Dust.on/4" do
    store = "test/store"
    Dust.SyncEngine.seed_entry(store, "a", 1, "integer")

    test_pid = self()
    callback = fn event -> send(test_pid, {:event, event}) end

    ref = Dust.watch(store, "**", callback, include_current: true)

    assert is_reference(ref)
    assert_receive {:event, %{type: :present, path: "a"}}, 200
  end
end
