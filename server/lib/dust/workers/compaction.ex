defmodule Dust.Workers.Compaction do
  @moduledoc """
  Oban cron worker that compacts store op logs into snapshots.

  For each store, compaction runs when:
  1. Op count exceeds threshold (default: 10,000), AND
  2. The oldest op is older than the plan's retention window.

  Compaction runs inside the store's SQLite file — reads entries,
  writes snapshot, deletes old ops, runs VACUUM.
  """
  use Oban.Worker, queue: :default

  require Logger

  import Ecto.Query
  alias Dust.Repo
  alias Dust.Stores.Store
  alias Dust.Sync.StoreDB

  @op_threshold 10_000

  @impl Oban.Worker
  def perform(_job) do
    stores = Repo.all(from(s in Store, where: s.status == :active, preload: [:organization]))

    Enum.each(stores, fn store ->
      try do
        maybe_compact(store)
      rescue
        e -> Logger.error("Compaction failed for store #{store.id}: #{inspect(e)}")
      end
    end)

    :ok
  end

  defp maybe_compact(store) do
    case StoreDB.read_conn(store.id) do
      {:ok, conn} ->
        op_count = query_int(conn, "SELECT count(*) FROM store_ops")

        if op_count >= @op_threshold do
          retention_days =
            Dust.Billing.Limits.for_plan(store.organization.plan || "free").retention_days

          oldest_ts = query_val(conn, "SELECT min(inserted_at) FROM store_ops")
          StoreDB.close(conn)

          if time_eligible?(oldest_ts, retention_days) do
            do_compact(store.id)
          end
        else
          StoreDB.close(conn)
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp time_eligible?(nil, _), do: false

  defp time_eligible?(oldest_ts, retention_days) when is_binary(oldest_ts) do
    case DateTime.from_iso8601(oldest_ts) do
      {:ok, dt, _} ->
        DateTime.diff(DateTime.utc_now(), dt, :day) >= retention_days

      _ ->
        false
    end
  end

  defp do_compact(store_id) do
    case StoreDB.write_conn(store_id) do
      {:ok, conn} ->
        try do
          Exqlite.Sqlite3.execute(conn, "BEGIN")

          max_seq = query_int(conn, "SELECT max(store_seq) FROM store_ops")

          if max_seq > 0 do
            # Read entries as snapshot data
            entries = query_all(conn, "SELECT path, value, type FROM store_entries", [])

            snapshot_data =
              Map.new(entries, fn [path, value, type] ->
                {path, %{"value" => Jason.decode!(value), "type" => type}}
              end)

            # Insert snapshot
            exec(conn, "INSERT INTO store_snapshots (snapshot_seq, snapshot_data) VALUES (?, ?)",
              [max_seq, Jason.encode!(snapshot_data)])

            # Delete compacted ops
            exec(conn, "DELETE FROM store_ops WHERE store_seq <= ?", [max_seq])

            # Delete older snapshots
            exec(conn, "DELETE FROM store_snapshots WHERE snapshot_seq < ?", [max_seq])

            Exqlite.Sqlite3.execute(conn, "COMMIT")

            # VACUUM outside transaction to reclaim space
            Exqlite.Sqlite3.execute(conn, "VACUUM")

            Logger.info("Compacted store #{store_id}: snapshot_seq=#{max_seq}")
          else
            Exqlite.Sqlite3.execute(conn, "ROLLBACK")
          end

          Exqlite.Sqlite3.close(conn)
          {:ok, max_seq}
        rescue
          e ->
            Exqlite.Sqlite3.execute(conn, "ROLLBACK")
            Exqlite.Sqlite3.close(conn)
            reraise e, __STACKTRACE__
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exec(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
  end

  defp query_int(conn, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    result = case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [val]} when is_integer(val) -> val
      _ -> 0
    end
    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  defp query_val(conn, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    result = case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [val]} -> val
      :done -> nil
    end
    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  defp query_all(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = collect_rows(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)
    rows
  end

  defp collect_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
