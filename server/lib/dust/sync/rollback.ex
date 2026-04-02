defmodule Dust.Sync.Rollback do
  @moduledoc """
  Rollback restores state to what it looked like at a previous `store_seq`.

  Rollback is always a **forward operation** — it never rewrites the op log.
  Rolling back to seq 40 creates NEW ops at the current seq that make state
  match what seq 40 looked like. The audit trail is preserved.

  Two granularities:
  - Path-level: restores a single key to its value at a given seq
  - Store-level: restores the entire store to a given seq
  """

  import Ecto.Query
  alias Dust.Repo
  alias Dust.Sync
  alias Dust.Sync.{StoreOp, StoreEntry}

  @rollback_device_id "system:rollback"

  @doc """
  Roll back a single path to its value at `to_seq`.

  Returns `{:ok, op}` with the new op that was written, or
  `{:error, reason}` if the rollback is not possible.
  """
  def rollback_path(store_id, path, to_seq) do
    with :ok <- validate_retention(store_id, to_seq) do
      historical_value = compute_historical_value(store_id, path, to_seq)
      current_value = current_path_value(store_id, path)

      if historical_value == current_value do
        {:ok, :noop}
      else
        write_rollback_op(store_id, path, historical_value, to_seq)
      end
    end
  end

  @doc """
  Roll back the entire store to its state at `to_seq`.

  Returns `{:ok, count}` where count is the number of ops written, or
  `{:error, reason}` if the rollback is not possible.
  """
  def rollback_store(store_id, to_seq) do
    with :ok <- validate_retention(store_id, to_seq) do
      historical_state = compute_historical_state(store_id, to_seq)
      current_entries = get_raw_entries(store_id)
      current_state = Map.new(current_entries, fn e -> {e.path, e.value} end)

      ops_written = 0

      # Delete entries that shouldn't exist in historical state
      ops_written =
        Enum.reduce(current_entries, ops_written, fn entry, count ->
          if Map.has_key?(historical_state, entry.path) do
            count
          else
            {:ok, _op} = write_rollback_op(store_id, entry.path, nil, to_seq)
            count + 1
          end
        end)

      # Set entries to historical values (changed or new)
      ops_written =
        Enum.reduce(historical_state, ops_written, fn {path, value}, count ->
          if Map.get(current_state, path) == value do
            count
          else
            {:ok, _op} = write_rollback_op(store_id, path, value, to_seq)
            count + 1
          end
        end)

      {:ok, ops_written}
    end
  end

  @doc """
  Verify the requested `to_seq` is within the available op log.
  """
  def validate_retention(store_id, to_seq) do
    earliest_seq =
      from(o in StoreOp,
        where: o.store_id == ^store_id,
        select: min(o.store_seq)
      )
      |> Repo.one()

    cond do
      is_nil(earliest_seq) ->
        {:error, :no_ops}

      to_seq < earliest_seq ->
        {:error, :beyond_retention}

      true ->
        :ok
    end
  end

  @doc """
  Compute what value a path had at a given `store_seq`.

  Returns the value, or `nil` if the path didn't exist at that point.
  """
  def compute_historical_value(store_id, path, to_seq) do
    from(o in StoreOp,
      where: o.store_id == ^store_id and o.path == ^path and o.store_seq <= ^to_seq,
      order_by: [desc: o.store_seq],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      %{op: :delete} -> nil
      %{value: value} -> value
    end
  end

  @doc """
  Compute the full store state at a given `store_seq` by replaying ops.

  Returns a map of `%{path => wrapped_value}`.
  """
  def compute_historical_state(store_id, to_seq) do
    from(o in StoreOp,
      where: o.store_id == ^store_id and o.store_seq <= ^to_seq,
      order_by: [asc: o.store_seq]
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn op, state ->
      apply_op_to_state(state, op)
    end)
  end

  # Apply a single op to the in-memory state map during replay.
  defp apply_op_to_state(state, %{op: :set, path: path, value: value}) do
    # Remove any descendants
    state = delete_descendants_from_state(state, path)
    Map.put(state, path, value)
  end

  defp apply_op_to_state(state, %{op: :delete, path: path}) do
    state
    |> Map.delete(path)
    |> delete_descendants_from_state(path)
  end

  defp apply_op_to_state(state, %{op: :merge, path: path, value: map}) when is_map(map) do
    Enum.reduce(map, state, fn
      {_key, _value}, state when not is_map(map) ->
        state

      {key, value}, state ->
        child_path = "#{path}.#{key}"
        Map.put(state, child_path, wrap_value(value))
    end)
  end

  defp apply_op_to_state(state, %{op: :increment, path: path, value: delta}) do
    current = unwrap_scalar(Map.get(state, path)) || 0
    delta_val = unwrap_scalar(delta) || 0
    Map.put(state, path, wrap_value(current + delta_val))
  end

  defp apply_op_to_state(state, %{op: :add, path: path, value: member}) do
    current_set = unwrap_set(Map.get(state, path))
    member_val = unwrap_scalar(member)
    new_set = Enum.uniq([member_val | current_set])
    Map.put(state, path, wrap_value(new_set))
  end

  defp apply_op_to_state(state, %{op: :remove, path: path, value: member}) do
    current_set = unwrap_set(Map.get(state, path))
    member_val = unwrap_scalar(member)
    new_set = List.delete(current_set, member_val)
    Map.put(state, path, wrap_value(new_set))
  end

  defp apply_op_to_state(state, _op), do: state

  defp delete_descendants_from_state(state, path) do
    prefix = path <> "."

    state
    |> Enum.reject(fn {k, _v} -> String.starts_with?(k, prefix) end)
    |> Map.new()
  end

  # Get all raw entries (without unwrapping values) for a store.
  defp get_raw_entries(store_id) do
    from(e in StoreEntry, where: e.store_id == ^store_id, order_by: e.path)
    |> Repo.all()
  end

  # Get the current value of a path (wrapped), or nil if it doesn't exist.
  defp current_path_value(store_id, path) do
    case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
      nil -> nil
      entry -> entry.value
    end
  end

  # Write a rollback op — either a :set to restore a value, or a :delete.
  defp write_rollback_op(store_id, path, nil, to_seq) do
    Sync.write(store_id, %{
      op: :delete,
      path: path,
      value: nil,
      device_id: @rollback_device_id,
      client_op_id: "rollback:#{to_seq}:#{path}"
    })
  end

  defp write_rollback_op(store_id, path, wrapped_value, to_seq) do
    Sync.write(store_id, %{
      op: :set,
      path: path,
      value: unwrap_for_write(wrapped_value),
      device_id: @rollback_device_id,
      client_op_id: "rollback:#{to_seq}:#{path}"
    })
  end

  # The Writer wraps values on the way in, so we need to unwrap stored values
  # before passing them back through the Writer.
  defp unwrap_for_write(%{"_scalar" => scalar}), do: scalar
  defp unwrap_for_write(%{"_typed" => v, "_type" => "decimal"}), do: Decimal.new(v)

  defp unwrap_for_write(%{"_typed" => v, "_type" => "datetime"}) do
    {:ok, dt, _} = DateTime.from_iso8601(v)
    dt
  end

  defp unwrap_for_write(value), do: value

  defp wrap_value(%Decimal{} = d), do: %{"_typed" => Decimal.to_string(d), "_type" => "decimal"}

  defp wrap_value(%DateTime{} = dt),
    do: %{"_typed" => DateTime.to_iso8601(dt), "_type" => "datetime"}

  defp wrap_value(value) when is_map(value), do: value
  defp wrap_value(value), do: %{"_scalar" => value}

  defp unwrap_scalar(%{"_scalar" => scalar}), do: scalar
  defp unwrap_scalar(%{"_typed" => v, "_type" => "decimal"}), do: Decimal.new(v)

  defp unwrap_scalar(%{"_typed" => v, "_type" => "datetime"}) do
    {:ok, dt, _} = DateTime.from_iso8601(v)
    dt
  end

  defp unwrap_scalar(nil), do: nil
  defp unwrap_scalar(value), do: value

  defp unwrap_set(%{"_scalar" => list}) when is_list(list), do: list
  defp unwrap_set(%{"_scalar" => _}), do: []
  defp unwrap_set(nil), do: []
  defp unwrap_set(_), do: []
end
