defmodule Dust.Workers.Compaction do
  @moduledoc """
  Oban cron worker that checks stores for compaction eligibility
  and dispatches compaction to the Writer GenServer.
  """
  use Oban.Worker, queue: :default

  require Logger

  import Ecto.Query
  alias Dust.Repo
  alias Dust.Stores.Store
  alias Dust.Sync.{StoreDB, Writer}

  @op_threshold 10_000

  @impl Oban.Worker
  def perform(_job) do
    stores = Repo.all(from(s in Store, where: s.status == :active, preload: [:organization]))

    Enum.each(stores, fn store ->
      case check_eligibility(store) do
        :eligible ->
          Logger.info("Compacting store #{store.id}")
          Writer.compact(store.id)

        :not_eligible ->
          :ok
      end
    end)

    :ok
  end

  defp check_eligibility(store) do
    case StoreDB.read_conn(store.id) do
      {:ok, conn} ->
        result = do_check(conn, store)
        StoreDB.close(conn)
        result

      {:error, :not_found} ->
        :not_eligible
    end
  end

  defp do_check(conn, store) do
    op_count = query_int(conn, "SELECT count(*) FROM store_ops")

    if op_count >= @op_threshold do
      retention_days =
        Dust.Billing.Limits.for_plan(store.organization.plan || "free").retention_days

      oldest_ts = query_val(conn, "SELECT min(inserted_at) FROM store_ops")

      if time_eligible?(oldest_ts, retention_days), do: :eligible, else: :not_eligible
    else
      :not_eligible
    end
  end

  defp time_eligible?(nil, _), do: false

  defp time_eligible?(oldest_ts, retention_days) when is_binary(oldest_ts) do
    case DateTime.from_iso8601(oldest_ts) do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt, :day) >= retention_days
      _ -> false
    end
  end

  defp query_int(conn, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [val]} when is_integer(val) -> val
        _ -> 0
      end

    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  defp query_val(conn, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [val]} -> val
        :done -> nil
      end

    Exqlite.Sqlite3.release(conn, stmt)
    result
  end
end
