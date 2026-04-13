defmodule Dust.SyncTest do
  use Dust.DataCase, async: false

  alias Dust.Accounts
  alias Dust.Stores
  alias Dust.Sync

  setup do
    {:ok, user} = Accounts.create_user(%{email: "sync-range@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "SyncRangeOrg", slug: "syncrangeorg"})

    {:ok, store} = Stores.create_store(org, %{name: "rangestore"})
    %{store: store}
  end

  defp seed(store, path, value) do
    {:ok, _op} =
      Sync.write(store.id, %{
        op: :set,
        path: path,
        value: value,
        device_id: "test-device",
        client_op_id: "seed-#{path}"
      })
  end

  describe "range_entries/4" do
    setup %{store: store} do
      seed(store, "a", 1)
      seed(store, "b", 2)
      seed(store, "c", 3)
      seed(store, "d", 4)
      seed(store, "e", 5)
      :ok
    end

    test "returns entries in [from, to) ascending", %{store: store} do
      assert {:ok, %{items: items, next_cursor: nil}} =
               Sync.range_entries(store.id, "b", "e", limit: 10)

      assert Enum.map(items, & &1.path) == ["b", "c", "d"]
      assert Enum.map(items, & &1.value) == [2, 3, 4]
      assert Enum.all?(items, &Map.has_key?(&1, :revision))
    end

    test "from is inclusive and to is exclusive", %{store: store} do
      assert {:ok, %{items: items}} =
               Sync.range_entries(store.id, "a", "c", limit: 10)

      assert Enum.map(items, & &1.path) == ["a", "b"]
    end

    test "from >= to returns empty items", %{store: store} do
      assert {:ok, %{items: [], next_cursor: nil}} =
               Sync.range_entries(store.id, "c", "c", limit: 10)

      assert {:ok, %{items: [], next_cursor: nil}} =
               Sync.range_entries(store.id, "e", "b", limit: 10)
    end

    test "desc order returns entries in reverse", %{store: store} do
      assert {:ok, %{items: items, next_cursor: nil}} =
               Sync.range_entries(store.id, "b", "e", limit: 10, order: :desc)

      assert Enum.map(items, & &1.path) == ["d", "c", "b"]
    end

    test "cursor continuation asc", %{store: store} do
      assert {:ok, %{items: page1, next_cursor: cursor}} =
               Sync.range_entries(store.id, "a", "e", limit: 2)

      assert Enum.map(page1, & &1.path) == ["a", "b"]
      assert cursor == "b"

      assert {:ok, %{items: page2, next_cursor: nil}} =
               Sync.range_entries(store.id, "a", "e", limit: 2, after: cursor)

      assert Enum.map(page2, & &1.path) == ["c", "d"]
    end

    test "cursor continuation desc", %{store: store} do
      assert {:ok, %{items: page1, next_cursor: cursor}} =
               Sync.range_entries(store.id, "a", "e", limit: 2, order: :desc)

      assert Enum.map(page1, & &1.path) == ["d", "c"]
      assert cursor == "c"

      assert {:ok, %{items: page2, next_cursor: nil}} =
               Sync.range_entries(store.id, "a", "e", limit: 2, order: :desc, after: cursor)

      assert Enum.map(page2, & &1.path) == ["b", "a"]
    end

    test "select: :keys returns path strings", %{store: store} do
      assert {:ok, %{items: items, next_cursor: nil}} =
               Sync.range_entries(store.id, "b", "e", limit: 10, select: :keys)

      assert items == ["b", "c", "d"]
    end

    test "select: :prefixes returns unsupported_select error", %{store: store} do
      assert {:error, :unsupported_select} =
               Sync.range_entries(store.id, "b", "e", select: :prefixes)
    end
  end

  describe "get_many_entries/2" do
    test "returns entries for present paths and missing for absent ones", %{store: store} do
      seed(store, "a", 1)
      seed(store, "b", 2)

      assert %{entries: entries, missing: missing} =
               Sync.get_many_entries(store.id, ["a", "b", "c"])

      assert %{value: 1, type: "integer", seq: seq_a} = entries["a"]
      assert is_integer(seq_a)
      assert %{value: 2, type: "integer", seq: seq_b} = entries["b"]
      assert is_integer(seq_b)
      assert missing == ["c"]
    end

    test "empty list returns empty result", %{store: store} do
      seed(store, "a", 1)

      assert %{entries: %{}, missing: []} = Sync.get_many_entries(store.id, [])
    end

    test "all-missing returns empty entries and full missing list", %{store: store} do
      seed(store, "a", 1)

      assert %{entries: entries, missing: missing} =
               Sync.get_many_entries(store.id, ["x", "y", "z"])

      assert entries == %{}
      assert Enum.sort(missing) == ["x", "y", "z"]
    end

    test "deduplicates input paths when missing", %{store: store} do
      seed(store, "a", 1)

      assert %{entries: %{}, missing: missing} =
               Sync.get_many_entries(store.id, ["m", "m", "m"])

      assert missing == ["m"]
    end

    test "deduplicates input paths when present", %{store: store} do
      seed(store, "a", 1)

      assert %{entries: entries, missing: []} =
               Sync.get_many_entries(store.id, ["a", "a", "a"])

      assert map_size(entries) == 1
      assert %{value: 1, type: "integer"} = entries["a"]
    end

    test "unwraps scalar values via ValueCodec", %{store: store} do
      seed(store, "name", "dust")
      seed(store, "count", 42)

      assert %{entries: entries, missing: []} =
               Sync.get_many_entries(store.id, ["name", "count"])

      assert %{value: "dust", type: "string"} = entries["name"]
      assert %{value: 42, type: "integer"} = entries["count"]
    end
  end
end
