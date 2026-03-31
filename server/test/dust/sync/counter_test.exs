defmodule Dust.Sync.CounterTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "counter@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Counter", slug: "counter"})
    {:ok, store} = Stores.create_store(org, %{name: "counts"})
    %{store: store}
  end

  describe "increment" do
    test "creates counter from nothing (starts at 0)", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :increment,
          path: "stats.views",
          value: 1,
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "stats.views")
      assert entry.value == 1
      assert entry.type == "counter"
    end

    test "sequential increments accumulate", %{store: store} do
      Sync.write(store.id, %{
        op: :increment,
        path: "stats.views",
        value: 3,
        device_id: "d1",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :increment,
        path: "stats.views",
        value: 5,
        device_id: "d1",
        client_op_id: "o2"
      })

      entry = Sync.get_entry(store.id, "stats.views")
      assert entry.value == 8
    end

    test "increment by negative value (decrement)", %{store: store} do
      Sync.write(store.id, %{
        op: :increment,
        path: "stats.views",
        value: 10,
        device_id: "d1",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :increment,
        path: "stats.views",
        value: -3,
        device_id: "d1",
        client_op_id: "o2"
      })

      entry = Sync.get_entry(store.id, "stats.views")
      assert entry.value == 7
    end

    test "set on counter path resets it", %{store: store} do
      Sync.write(store.id, %{
        op: :increment,
        path: "stats.views",
        value: 10,
        device_id: "d1",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :set,
        path: "stats.views",
        value: 0,
        device_id: "d1",
        client_op_id: "o2"
      })

      entry = Sync.get_entry(store.id, "stats.views")
      assert entry.value == 0
    end

    test "concurrent increments via two sequential writes sum correctly", %{store: store} do
      # Simulates two devices both incrementing in sequence (server processes one at a time)
      Sync.write(store.id, %{
        op: :increment,
        path: "stats.views",
        value: 3,
        device_id: "dev_a",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :increment,
        path: "stats.views",
        value: 5,
        device_id: "dev_b",
        client_op_id: "o2"
      })

      entry = Sync.get_entry(store.id, "stats.views")
      assert entry.value == 8
    end
  end
end
