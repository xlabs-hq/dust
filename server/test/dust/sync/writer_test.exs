defmodule Dust.Sync.WriterTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "writer@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "test"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store}
  end

  describe "write/1" do
    test "set assigns store_seq and persists", %{store: store} do
      {:ok, event} =
        Sync.write(store.id, %{
          op: :set,
          path: "posts.hello",
          value: %{"title" => "Hello"},
          device_id: "dev_1",
          client_op_id: "op_1"
        })

      assert event.store_seq == 1
      assert event.op == :set
      assert event.path == "posts.hello"

      # Verify materialized entry
      entry = Sync.get_entry(store.id, "posts.hello")
      assert entry.value == %{"title" => "Hello"}
      assert entry.seq == 1
    end

    test "sequential writes increment store_seq", %{store: store} do
      {:ok, e1} =
        Sync.write(store.id, %{
          op: :set,
          path: "a",
          value: "1",
          device_id: "d",
          client_op_id: "o1"
        })

      {:ok, e2} =
        Sync.write(store.id, %{
          op: :set,
          path: "b",
          value: "2",
          device_id: "d",
          client_op_id: "o2"
        })

      assert e1.store_seq == 1
      assert e2.store_seq == 2
    end

    test "delete removes entry", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "x", value: "v", device_id: "d", client_op_id: "o1"})

      {:ok, _} =
        Sync.write(store.id, %{
          op: :delete,
          path: "x",
          value: nil,
          device_id: "d",
          client_op_id: "o2"
        })

      assert Sync.get_entry(store.id, "x") == nil
    end

    test "merge updates named children only", %{store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "settings.theme",
        value: "light",
        device_id: "d",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :set,
        path: "settings.locale",
        value: "en",
        device_id: "d",
        client_op_id: "o2"
      })

      Sync.write(store.id, %{
        op: :merge,
        path: "settings",
        value: %{"theme" => "dark"},
        device_id: "d",
        client_op_id: "o3"
      })

      assert Sync.get_entry(store.id, "settings.theme").value == "dark"
      assert Sync.get_entry(store.id, "settings.locale").value == "en"
    end
  end

  describe "get_ops_since/2" do
    test "returns ops after given seq", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})
      Sync.write(store.id, %{op: :set, path: "c", value: "3", device_id: "d", client_op_id: "o3"})

      ops = Sync.get_ops_since(store.id, 1)
      assert length(ops) == 2
      assert Enum.map(ops, & &1.store_seq) == [2, 3]
    end
  end
end
