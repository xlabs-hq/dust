defmodule Dust.Sync.DiffTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "diff@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "difftest"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store}
  end

  test "shows additions from seq 0", %{store: store} do
    Sync.write(store.id, %{op: :set, path: "x", value: "new", device_id: "d", client_op_id: "o1"})

    {:ok, diff} = Dust.Sync.Diff.changes(store.id, 0, 1)
    assert length(diff.changes) == 1

    [change] = diff.changes
    assert change.path == "x"
    assert change.before == nil
    assert change.after == "new"
  end

  test "shows modifications and deletions", %{store: store} do
    Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
    Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})
    # Now: a=1, b=2 at seq 2
    Sync.write(store.id, %{op: :set, path: "a", value: "updated", device_id: "d", client_op_id: "o3"})
    Sync.write(store.id, %{op: :delete, path: "b", value: nil, device_id: "d", client_op_id: "o4"})
    # Now: a=updated at seq 4, b deleted

    {:ok, diff} = Dust.Sync.Diff.changes(store.id, 2, 4)
    changes = Map.new(diff.changes, fn c -> {c.path, c} end)

    assert changes["a"].before == "1"
    assert changes["a"].after == "updated"
    assert changes["b"].before == "2"
    assert changes["b"].after == nil
  end

  test "returns empty changes when nothing changed", %{store: store} do
    Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})

    {:ok, diff} = Dust.Sync.Diff.changes(store.id, 1, 1)
    assert diff.changes == []
  end

  test "defaults to_seq to current seq when nil", %{store: store} do
    Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
    Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})

    {:ok, diff} = Dust.Sync.Diff.changes(store.id, 0, nil)
    assert diff.to_seq == 2
    assert length(diff.changes) == 2
  end

  test "returns error when from_seq is before compaction point", %{store: store} do
    Enum.each(1..5, fn i ->
      Sync.write(store.id, %{
        op: :set,
        path: "k#{i}",
        value: "v",
        device_id: "d",
        client_op_id: "o#{i}"
      })
    end)

    Dust.Sync.Writer.compact(store.id)

    assert {:error, :compacted, %{earliest_available: _}} =
             Dust.Sync.Diff.changes(store.id, 1, 5)
  end
end
