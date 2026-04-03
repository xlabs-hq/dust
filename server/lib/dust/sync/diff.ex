defmodule Dust.Sync.Diff do
  @moduledoc """
  Computes the difference in store state between two sequence points.

  Uses `Rollback.compute_historical_state/2` to reconstruct state at both
  the `from_seq` and `to_seq` points, then diffs them to produce a list
  of changes (additions, modifications, and deletions).
  """

  alias Dust.Sync
  alias Dust.Sync.{Rollback, ValueCodec}

  def changes(store_id, from_seq, to_seq) do
    to_seq = to_seq || Sync.current_seq(store_id)

    with :ok <- check_compaction_boundary(store_id, from_seq) do
      before_state =
        if from_seq > 0, do: Rollback.compute_historical_state(store_id, from_seq), else: %{}

      after_state = Rollback.compute_historical_state(store_id, to_seq) || %{}

      all_paths =
        MapSet.union(
          MapSet.new(Map.keys(before_state || %{})),
          MapSet.new(Map.keys(after_state))
        )

      changes =
        all_paths
        |> Enum.map(fn path ->
          before_val = unwrap_val(Map.get(before_state || %{}, path))
          after_val = unwrap_val(Map.get(after_state, path))

          if before_val != after_val do
            %{path: path, before: before_val, after: after_val}
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.path)

      {:ok, %{from_seq: from_seq, to_seq: to_seq, changes: changes}}
    end
  end

  defp check_compaction_boundary(_store_id, from_seq) when from_seq <= 0, do: :ok

  defp check_compaction_boundary(store_id, from_seq) do
    case Sync.get_latest_snapshot(store_id) do
      %{snapshot_seq: snap_seq} when from_seq < snap_seq ->
        {:error, :compacted, %{earliest_available: snap_seq}}

      _ ->
        case Sync.earliest_op_seq(store_id) do
          nil ->
            :ok

          earliest when from_seq < earliest ->
            {:error, :compacted, %{earliest_available: earliest}}

          _ ->
            :ok
        end
    end
  end

  defp unwrap_val(nil), do: nil
  defp unwrap_val(value), do: ValueCodec.unwrap(value)
end
