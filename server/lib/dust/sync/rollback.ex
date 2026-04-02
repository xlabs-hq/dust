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
  alias Dust.Sync.{StoreOp, StoreEntry, ValueCodec}

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

  Handles ancestor ops: if `set("docs", %{readme: "hello"})` was the
  most recent op affecting "docs.readme", this function extracts the
  value from the ancestor's map.
  """
  def compute_historical_value(store_id, path, to_seq) do
    # First check for a direct op on this exact path
    direct_op =
      from(o in StoreOp,
        where: o.store_id == ^store_id and o.path == ^path and o.store_seq <= ^to_seq,
        order_by: [desc: o.store_seq],
        limit: 1
      )
      |> Repo.one()

    # Also check ancestor ops that might have set/deleted this path as part of a subtree
    {:ok, segments} = DustProtocol.Path.parse(path)
    ancestor_op = find_most_recent_ancestor_op(store_id, segments, to_seq)

    # The more recent op wins
    case {direct_op, ancestor_op} do
      {nil, nil} ->
        nil

      {nil, ancestor} ->
        extract_descendant_value(ancestor, segments)

      {direct, nil} ->
        case direct do
          %{op: :delete} -> nil
          %{value: value} -> value
        end

      {direct, ancestor} ->
        if ancestor.store_seq > direct.store_seq do
          extract_descendant_value(ancestor, segments)
        else
          case direct do
            %{op: :delete} -> nil
            %{value: value} -> value
          end
        end
    end
  end

  # Find the most recent set or delete on any ancestor path.
  defp find_most_recent_ancestor_op(store_id, segments, to_seq) when length(segments) > 1 do
    ancestor_paths =
      segments
      |> Enum.slice(0..-2//1)
      |> Enum.scan(fn seg, acc -> "#{acc}.#{seg}" end)

    from(o in StoreOp,
      where:
        o.store_id == ^store_id and o.path in ^ancestor_paths and
          o.store_seq <= ^to_seq and o.op in [:set, :delete],
      order_by: [desc: o.store_seq],
      limit: 1
    )
    |> Repo.one()
  end

  defp find_most_recent_ancestor_op(_, _, _), do: nil

  # Extract a descendant value from an ancestor set op's map value.
  defp extract_descendant_value(%{op: :delete}, _segments), do: nil

  defp extract_descendant_value(%{op: :set, path: ancestor_path, value: value}, segments) do
    {:ok, ancestor_segments} = DustProtocol.Path.parse(ancestor_path)
    relative_keys = Enum.drop(segments, length(ancestor_segments))

    Enum.reduce_while(relative_keys, ValueCodec.unwrap(value), fn key, acc ->
      case acc do
        %{^key => child} -> {:cont, child}
        _ -> {:halt, nil}
      end
    end)
    |> case do
      nil -> nil
      val -> ValueCodec.wrap(val)
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
  # Mirrors what the Writer does: plain maps expand into leaf entries.
  defp apply_op_to_state(state, %{op: :set, path: path, value: value}) do
    state = delete_descendants_from_state(state, path)
    unwrapped = ValueCodec.unwrap(value)

    if is_map(unwrapped) and not ValueCodec.typed_value?(unwrapped) do
      # Expand map into leaf entries (same as Writer)
      state = Map.delete(state, path)
      leaves = ValueCodec.flatten_map(path, unwrapped)

      Enum.reduce(leaves, state, fn {leaf_path, leaf_value}, acc ->
        Map.put(acc, leaf_path, ValueCodec.wrap(leaf_value))
      end)
    else
      Map.put(state, path, value)
    end
  end

  defp apply_op_to_state(state, %{op: :delete, path: path}) do
    state
    |> Map.delete(path)
    |> delete_descendants_from_state(path)
  end

  defp apply_op_to_state(state, %{op: :merge, path: path, value: map}) when is_map(map) do
    Enum.reduce(map, state, fn {key, value}, state ->
      child_path = "#{path}.#{key}"
      unwrapped = ValueCodec.unwrap(value)

      if is_map(unwrapped) and not ValueCodec.typed_value?(unwrapped) do
        state = delete_descendants_from_state(state, child_path)
        state = Map.delete(state, child_path)
        leaves = ValueCodec.flatten_map(child_path, unwrapped)

        Enum.reduce(leaves, state, fn {leaf_path, leaf_value}, acc ->
          Map.put(acc, leaf_path, ValueCodec.wrap(leaf_value))
        end)
      else
        Map.put(state, child_path, ValueCodec.wrap(unwrapped))
      end
    end)
  end

  defp apply_op_to_state(state, %{op: :increment, path: path, value: delta}) do
    current = ValueCodec.unwrap(Map.get(state, path)) || 0
    delta_val = ValueCodec.unwrap(delta) || 0
    Map.put(state, path, ValueCodec.wrap(current + delta_val))
  end

  defp apply_op_to_state(state, %{op: :add, path: path, value: member}) do
    current_set = ValueCodec.unwrap_set(Map.get(state, path))
    member_val = ValueCodec.unwrap(member)
    new_set = Enum.uniq([member_val | current_set])
    Map.put(state, path, ValueCodec.wrap(new_set))
  end

  defp apply_op_to_state(state, %{op: :remove, path: path, value: member}) do
    current_set = ValueCodec.unwrap_set(Map.get(state, path))
    member_val = ValueCodec.unwrap(member)
    new_set = List.delete(current_set, member_val)
    Map.put(state, path, ValueCodec.wrap(new_set))
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
    case Sync.get_entry(store_id, path) do
      nil -> nil
      entry -> ValueCodec.wrap(entry.value)
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
      value: ValueCodec.unwrap(wrapped_value),
      device_id: @rollback_device_id,
      client_op_id: "rollback:#{to_seq}:#{path}"
    })
  end

end
