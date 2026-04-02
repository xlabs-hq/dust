defmodule Dust.Workers.CompactionTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}
  alias Dust.Sync.{StoreOp, StoreSnapshot}

  import Ecto.Query

  setup do
    {:ok, user} = Accounts.create_user(%{email: "compact@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "compact"})
    {:ok, store} = Stores.create_store(org, %{name: "data"})
    %{store: store, org: org}
  end

  defp write_n_ops(store_id, n) do
    Enum.each(1..n, fn i ->
      Sync.write(store_id, %{
        op: :set,
        path: "key#{i}",
        value: "val#{i}",
        device_id: "d",
        client_op_id: "o#{i}"
      })
    end)
  end

  defp op_count(store_id) do
    Repo.one(from(o in StoreOp, where: o.store_id == ^store_id, select: count()))
  end

  defp snapshot_count(store_id) do
    Repo.one(from(s in StoreSnapshot, where: s.store_id == ^store_id, select: count()))
  end

  test "compaction does nothing when op count is below threshold", %{store: store} do
    write_n_ops(store.id, 100)

    Dust.Workers.Compaction.perform(%Oban.Job{})

    assert op_count(store.id) == 100
    assert snapshot_count(store.id) == 0
  end

  test "writer continues correct seq after compaction", %{store: store, org: org} do
    write_n_ops(store.id, 5)

    # Manually compact (bypass threshold)
    # Simulate by inserting a snapshot and deleting ops
    entries =
      Repo.all(from(e in Dust.Sync.StoreEntry, where: e.store_id == ^store.id))
      |> Map.new(fn e -> {e.path, %{value: e.value, type: e.type}} end)

    Repo.insert!(%StoreSnapshot{
      store_id: store.id,
      snapshot_seq: 5,
      snapshot_data: entries
    })

    from(o in StoreOp, where: o.store_id == ^store.id)
    |> Repo.delete_all()

    assert op_count(store.id) == 0

    # Write after compaction — should get seq 6, not 1
    {:ok, op} =
      Sync.write(store.id, %{
        op: :set,
        path: "after_compact",
        value: "works",
        device_id: "d",
        client_op_id: "post_compact"
      })

    assert op.store_seq == 6
  end

  test "catch-up sends snapshot when client is behind", %{store: store} do
    write_n_ops(store.id, 5)

    # Create a snapshot at seq 5
    entries =
      Repo.all(from(e in Dust.Sync.StoreEntry, where: e.store_id == ^store.id))
      |> Map.new(fn e -> {e.path, %{value: e.value, type: e.type}} end)

    Repo.insert!(%StoreSnapshot{
      store_id: store.id,
      snapshot_seq: 5,
      snapshot_data: entries
    })

    # Delete ops (as compaction would)
    from(o in StoreOp, where: o.store_id == ^store.id)
    |> Repo.delete_all()

    # Verify snapshot is returned
    snapshot = Sync.get_latest_snapshot(store.id)
    assert snapshot.snapshot_seq == 5
    assert map_size(snapshot.snapshot_data) == 5
  end
end
