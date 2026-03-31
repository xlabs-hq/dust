defmodule Dust.Sync.AuditTest do
  use Dust.DataCase

  alias Dust.{Accounts, Stores, Sync}
  alias Dust.Sync.Audit

  setup do
    {:ok, user} = Accounts.create_user(%{email: "audit@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "audit-org"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})

    # Write some ops for testing
    for {path, device, op_type, value, i} <- [
          {"users.alice", "dev_1", :set, %{"name" => "Alice"}, 1},
          {"users.bob", "dev_1", :set, %{"name" => "Bob"}, 2},
          {"settings.theme", "dev_2", :set, "dark", 3},
          {"users.alice", "dev_1", :merge, %{"age" => 30}, 4},
          {"users.bob", "dev_2", :delete, nil, 5}
        ] do
      Sync.write(store.id, %{
        op: op_type,
        path: path,
        value: value,
        device_id: device,
        client_op_id: "op_#{i}"
      })
    end

    %{store: store}
  end

  describe "query_ops/2" do
    test "returns all ops in descending seq order", %{store: store} do
      ops = Audit.query_ops(store.id)
      assert length(ops) == 5
      seqs = Enum.map(ops, & &1.store_seq)
      assert seqs == Enum.sort(seqs, :desc)
    end

    test "respects limit", %{store: store} do
      ops = Audit.query_ops(store.id, limit: 2)
      assert length(ops) == 2
    end

    test "respects offset", %{store: store} do
      ops = Audit.query_ops(store.id, limit: 2, offset: 2)
      assert length(ops) == 2
      # Should skip the 2 most recent (seq 5, 4), returning seq 3, 2
      seqs = Enum.map(ops, & &1.store_seq)
      assert seqs == [3, 2]
    end

    test "filters by exact path", %{store: store} do
      ops = Audit.query_ops(store.id, path: "users.alice")
      assert length(ops) == 2
      assert Enum.all?(ops, &(&1.path == "users.alice"))
    end

    test "filters by wildcard path", %{store: store} do
      ops = Audit.query_ops(store.id, path: "users.*")
      # * becomes % for SQL LIKE — matches users.alice and users.bob ops
      assert length(ops) == 4
      assert Enum.all?(ops, &String.starts_with?(&1.path, "users."))
    end

    test "filters by glob wildcard path", %{store: store} do
      ops = Audit.query_ops(store.id, path: "settings.*")
      assert length(ops) == 1
      assert hd(ops).path == "settings.theme"
    end

    test "filters by device_id", %{store: store} do
      ops = Audit.query_ops(store.id, device_id: "dev_2")
      assert length(ops) == 2
      assert Enum.all?(ops, &(&1.device_id == "dev_2"))
    end

    test "filters by op type (string)", %{store: store} do
      ops = Audit.query_ops(store.id, op: "delete")
      assert length(ops) == 1
      assert hd(ops).op == :delete
    end

    test "filters by op type (atom)", %{store: store} do
      ops = Audit.query_ops(store.id, op: :merge)
      assert length(ops) == 1
      assert hd(ops).op == :merge
    end

    test "combines multiple filters", %{store: store} do
      ops = Audit.query_ops(store.id, path: "users.alice", op: "set")
      assert length(ops) == 1
      assert hd(ops).path == "users.alice"
      assert hd(ops).op == :set
    end
  end

  describe "count_ops/2" do
    test "counts all ops", %{store: store} do
      assert Audit.count_ops(store.id) == 5
    end

    test "counts with filters", %{store: store} do
      assert Audit.count_ops(store.id, device_id: "dev_1") == 3
      assert Audit.count_ops(store.id, op: "delete") == 1
    end
  end
end
