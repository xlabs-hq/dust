defmodule Dust.Sync.SetTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "set@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "SetOrg", slug: "setorg"})
    {:ok, store} = Stores.create_store(org, %{name: "tags"})
    %{store: store}
  end

  describe "add" do
    test "creates set from nothing", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :add,
          path: "post.tags",
          value: "elixir",
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "post.tags")
      assert entry.value == ["elixir"]
      assert entry.type == "set"
    end

    test "add is idempotent (adding same member twice does not duplicate)", %{store: store} do
      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "elixir",
        device_id: "d1",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "elixir",
        device_id: "d1",
        client_op_id: "o2"
      })

      entry = Sync.get_entry(store.id, "post.tags")
      assert entry.value == ["elixir"]
    end

    test "concurrent adds of different members both survive", %{store: store} do
      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "elixir",
        device_id: "dev_a",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "rust",
        device_id: "dev_b",
        client_op_id: "o2"
      })

      entry = Sync.get_entry(store.id, "post.tags")
      assert is_list(entry.value)
      assert "elixir" in entry.value
      assert "rust" in entry.value
    end
  end

  describe "remove" do
    test "removes a member", %{store: store} do
      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "elixir",
        device_id: "d1",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "rust",
        device_id: "d1",
        client_op_id: "o2"
      })

      Sync.write(store.id, %{
        op: :remove,
        path: "post.tags",
        value: "elixir",
        device_id: "d1",
        client_op_id: "o3"
      })

      entry = Sync.get_entry(store.id, "post.tags")
      assert entry.value == ["rust"]
    end

    test "remove from nonexistent set is a no-op", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :remove,
          path: "post.tags",
          value: "elixir",
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "post.tags")
      assert entry.value == []
    end
  end

  describe "set on set path" do
    test "replaces entire set", %{store: store} do
      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "elixir",
        device_id: "d1",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :add,
        path: "post.tags",
        value: "rust",
        device_id: "d1",
        client_op_id: "o2"
      })

      # :set replaces the entire set with LWW
      Sync.write(store.id, %{
        op: :set,
        path: "post.tags",
        value: ["go"],
        device_id: "d1",
        client_op_id: "o3"
      })

      entry = Sync.get_entry(store.id, "post.tags")
      assert entry.value == ["go"]
    end
  end
end
