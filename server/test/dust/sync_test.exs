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

  describe "CAS writes" do
    test "set with matching if_match succeeds", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "k",
          value: 1,
          device_id: "d",
          client_op_id: "c1"
        })

      %{seq: seq} = Sync.get_entry(store.id, "k")

      assert {:ok, %{store_seq: _}} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "k",
                 value: 2,
                 device_id: "d",
                 client_op_id: "c2",
                 if_match: seq
               })

      assert %{value: 2} = Sync.get_entry(store.id, "k")
    end

    test "set with stale if_match returns :conflict", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "k",
          value: 1,
          device_id: "d",
          client_op_id: "c1"
        })

      %{seq: stale_seq} = Sync.get_entry(store.id, "k")

      # Bump the seq with another write
      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "k",
          value: 2,
          device_id: "d",
          client_op_id: "c2"
        })

      assert {:error, :conflict} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "k",
                 value: 3,
                 device_id: "d",
                 client_op_id: "c3",
                 if_match: stale_seq
               })

      # Verify the entry was NOT updated
      assert %{value: 2} = Sync.get_entry(store.id, "k")
    end

    test "set with if_match on a missing path returns :conflict", %{store: store} do
      assert {:error, :conflict} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "missing",
                 value: 1,
                 device_id: "d",
                 client_op_id: "c1",
                 if_match: 42
               })
    end

    test "set without if_match is LWW as before", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "k",
          value: 1,
          device_id: "d",
          client_op_id: "c1"
        })

      assert {:ok, _} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "k",
                 value: 2,
                 device_id: "d",
                 client_op_id: "c2"
               })

      assert %{value: 2} = Sync.get_entry(store.id, "k")
    end
  end

  describe "if_absent (put_new) writes" do
    test "set with if_absent on a missing key succeeds", %{store: store} do
      assert {:ok, %{store_seq: _}} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "claim",
                 value: 1,
                 device_id: "d",
                 client_op_id: "c1",
                 if_absent: true
               })

      assert %{value: 1} = Sync.get_entry(store.id, "claim")
    end

    test "set with if_absent on an existing key returns :exists and does not write", %{
      store: store
    } do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "claim",
          value: 1,
          device_id: "d",
          client_op_id: "c1"
        })

      assert {:error, :exists} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "claim",
                 value: 2,
                 device_id: "d",
                 client_op_id: "c2",
                 if_absent: true
               })

      assert %{value: 1} = Sync.get_entry(store.id, "claim")
    end

    test "if_absent combined with if_match is rejected", %{store: store} do
      assert {:error, :invalid_precondition} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "claim",
                 value: 1,
                 device_id: "d",
                 client_op_id: "c1",
                 if_absent: true,
                 if_match: 3
               })
    end

    test "if_absent on a delete op is rejected", %{store: store} do
      assert {:error, :if_absent_unsupported_op} =
               Sync.write(store.id, %{
                 op: :delete,
                 path: "claim",
                 device_id: "d",
                 client_op_id: "c1",
                 if_absent: true
               })
    end
  end

  describe "leases" do
    test "acquire on an absent key stamps holder, token, expires_at", %{store: store} do
      assert {:ok, op} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
      env = op.materialized_value
      assert env["_type"] == "lease"
      assert env["holder"] == "node-1"
      assert env["token"] == op.store_seq
      assert is_integer(env["expires_at"])
    end

    test "acquire on a live-held lease returns :held", %{store: store} do
      {:ok, _} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
      assert {:error, :held} = Sync.lease(store.id, "lock/a", 60_000, "node-2")
    end

    test "an expired lease is stolen atomically with a fresh token", %{store: store} do
      {:ok, first} = Sync.lease(store.id, "lock/a", 0, "node-1")
      assert {:ok, second} = Sync.lease(store.id, "lock/a", 60_000, "node-2")
      assert second.materialized_value["holder"] == "node-2"
      assert second.materialized_value["token"] > first.materialized_value["token"]
    end

    test "acquire on a key holding a non-lease value returns :occupied", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "lock/a",
          value: 1,
          device_id: "d",
          client_op_id: "c"
        })

      assert {:error, :occupied} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
    end

    test "renew keeps the token and extends expiry", %{store: store} do
      {:ok, op} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
      token = op.materialized_value["token"]
      exp1 = op.materialized_value["expires_at"]

      assert {:ok, renewed} = Sync.renew_lease(store.id, "lock/a", token, 120_000)
      assert renewed.materialized_value["token"] == token
      assert renewed.materialized_value["expires_at"] >= exp1
    end

    test "renew with a wrong token returns :not_held", %{store: store} do
      {:ok, _} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
      assert {:error, :not_held} = Sync.renew_lease(store.id, "lock/a", 999_999, 60_000)
    end

    test "renew on an expired lease returns :not_held", %{store: store} do
      {:ok, op} = Sync.lease(store.id, "lock/a", 0, "node-1")
      token = op.materialized_value["token"]
      assert {:error, :not_held} = Sync.renew_lease(store.id, "lock/a", token, 60_000)
    end

    test "release with the matching token deletes the lease", %{store: store} do
      {:ok, op} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
      token = op.materialized_value["token"]

      assert {:ok, %{store_seq: _}} = Sync.release_lease(store.id, "lock/a", token)
      assert is_nil(Sync.get_entry(store.id, "lock/a"))
    end

    test "release with a wrong token is an idempotent no-op", %{store: store} do
      {:ok, _} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
      assert {:ok, :noop} = Sync.release_lease(store.id, "lock/a", 999_999)
      # The real lease is untouched.
      refute is_nil(Sync.get_entry(store.id, "lock/a"))
    end

    test "fence: a write guarded by a live held lease succeeds", %{store: store} do
      {:ok, op} = Sync.lease(store.id, "lock/a", 60_000, "node-1")
      token = op.materialized_value["token"]

      assert {:ok, %{store_seq: _}} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "result/a",
                 value: "done",
                 device_id: "d",
                 client_op_id: "c",
                 fence: %{key: "lock/a", token: token}
               })

      assert %{value: "done"} = Sync.get_entry(store.id, "result/a")
    end

    test "fence: a write with a stale token is rejected with :fenced", %{store: store} do
      {:ok, _} = Sync.lease(store.id, "lock/a", 60_000, "node-1")

      assert {:error, :fenced} =
               Sync.write(store.id, %{
                 op: :set,
                 path: "result/a",
                 value: "stale",
                 device_id: "d",
                 client_op_id: "c",
                 fence: %{key: "lock/a", token: 999_999}
               })

      assert is_nil(Sync.get_entry(store.id, "result/a"))
    end
  end
end
