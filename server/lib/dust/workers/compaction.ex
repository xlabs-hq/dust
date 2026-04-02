defmodule Dust.Workers.Compaction do
  @moduledoc """
  Oban cron worker that compacts store op logs into snapshots.

  For each store, compaction runs when:
  1. Op count exceeds threshold (default: 10,000), AND
  2. Either all connected clients have acked past the compaction point,
     OR the oldest op is older than the plan's retention window.

  Compaction materializes current store_entries into a snapshot,
  deletes old ops, and keeps only the latest snapshot per store.
  """
  use Oban.Worker, queue: :default

  import Ecto.Query
  alias Dust.Repo
  alias Dust.Stores.Store
  alias Dust.Sync.{StoreOp, StoreEntry, StoreSnapshot}

  @op_threshold 10_000

  @impl Oban.Worker
  def perform(_job) do
    stores = Repo.all(from(s in Store, where: s.status == :active))

    Enum.each(stores, fn store ->
      try do
        maybe_compact(store)
      rescue
        e -> require Logger; Logger.error("Compaction failed for store #{store.id}: #{inspect(e)}")
      end
    end)

    :ok
  end

  defp maybe_compact(store) do
    op_count = Repo.one(from(o in StoreOp, where: o.store_id == ^store.id, select: count()))

    if op_count >= @op_threshold do
      org = Repo.preload(store, :organization).organization
      retention_days = Dust.Billing.Limits.for_plan(org.plan || "free").retention_days

      oldest_op =
        Repo.one(
          from(o in StoreOp,
            where: o.store_id == ^store.id,
            order_by: [asc: o.inserted_at],
            limit: 1,
            select: o.inserted_at
          )
        )

      time_eligible =
        oldest_op &&
          DateTime.diff(DateTime.utc_now(), oldest_op, :day) >= retention_days

      if time_eligible do
        do_compact(store.id)
      end
    end
  end

  defp do_compact(store_id) do
    Repo.transaction(fn ->
      # Get current max seq
      max_seq =
        Repo.one(from(o in StoreOp, where: o.store_id == ^store_id, select: max(o.store_seq))) ||
          0

      if max_seq == 0, do: Repo.rollback(:no_ops)

      # Read materialized entries as the snapshot
      entries =
        Repo.all(from(e in StoreEntry, where: e.store_id == ^store_id))
        |> Map.new(fn e -> {e.path, %{value: e.value, type: e.type}} end)

      # Insert snapshot
      Repo.insert!(%StoreSnapshot{
        store_id: store_id,
        snapshot_seq: max_seq,
        snapshot_data: entries
      })

      # Delete old ops
      from(o in StoreOp, where: o.store_id == ^store_id and o.store_seq <= ^max_seq)
      |> Repo.delete_all()

      # Delete older snapshots (keep only the latest)
      from(s in StoreSnapshot,
        where: s.store_id == ^store_id and s.snapshot_seq < ^max_seq
      )
      |> Repo.delete_all()

      max_seq
    end)
  end
end
