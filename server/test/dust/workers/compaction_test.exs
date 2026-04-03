defmodule Dust.Workers.CompactionTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}
  alias Dust.Sync.StoreDB

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
    sqlite_count(store_id, "store_ops")
  end

  defp snapshot_count(store_id) do
    sqlite_count(store_id, "store_snapshots")
  end

  defp sqlite_count(store_id, table) do
    case StoreDB.read_conn(store_id) do
      {:ok, conn} ->
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT count(*) FROM #{table}")
        {:row, [count]} = Exqlite.Sqlite3.step(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)
        StoreDB.close(conn)
        count

      _ ->
        0
    end
  end

  test "compaction does nothing when op count is below threshold", %{store: store} do
    write_n_ops(store.id, 100)

    Dust.Workers.Compaction.perform(%Oban.Job{})

    assert op_count(store.id) == 100
    assert snapshot_count(store.id) == 0
  end

  test "writer continues correct seq after compaction", %{store: store} do
    write_n_ops(store.id, 5)

    # Manually compact via SQLite
    simulate_compaction(store.id, 5)

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

    simulate_compaction(store.id, 5)

    # Verify snapshot is returned
    snapshot = Sync.get_latest_snapshot(store.id)
    assert snapshot.snapshot_seq == 5
    assert map_size(snapshot.snapshot_data) == 5
  end

  # Simulate compaction by reading entries, inserting snapshot, deleting ops
  defp simulate_compaction(store_id, seq) do
    {:ok, conn} = StoreDB.read_conn(store_id)

    # Read entries
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT path, value, type FROM store_entries")
    entries = collect_rows(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    StoreDB.close(conn)

    snapshot_data =
      Map.new(entries, fn [path, value, type] ->
        {path, %{"value" => Jason.decode!(value), "type" => type}}
      end)

    # Write snapshot and delete ops using a write connection
    {:ok, wconn} = StoreDB.write_conn(store_id)

    {:ok, ins} =
      Exqlite.Sqlite3.prepare(
        wconn,
        "INSERT INTO store_snapshots (snapshot_seq, snapshot_data) VALUES (?, ?)"
      )

    Exqlite.Sqlite3.bind(ins, [seq, Jason.encode!(snapshot_data)])
    :done = Exqlite.Sqlite3.step(wconn, ins)
    Exqlite.Sqlite3.release(wconn, ins)

    Exqlite.Sqlite3.execute(wconn, "DELETE FROM store_ops")
    Exqlite.Sqlite3.close(wconn)
  end

  defp collect_rows(conn, stmt) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> [row | collect_rows(conn, stmt)]
      :done -> []
    end
  end
end
