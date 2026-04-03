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

  alias Dust.Sync
  alias Dust.Sync.{StoreDB, ValueCodec}

  @rollback_device_id "system:rollback"

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

  def rollback_store(store_id, to_seq) do
    with :ok <- validate_retention(store_id, to_seq) do
      historical_state = compute_historical_state(store_id, to_seq)
      current_entries = get_raw_entries(store_id)
      current_state = Map.new(current_entries, fn {path, value} -> {path, value} end)

      ops_written = 0

      ops_written =
        Enum.reduce(current_entries, ops_written, fn {path, _value}, count ->
          if Map.has_key?(historical_state, path) do
            count
          else
            {:ok, _op} = write_rollback_op(store_id, path, nil, to_seq)
            count + 1
          end
        end)

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

  def validate_retention(store_id, to_seq) do
    with_read_conn(store_id, fn conn ->
      earliest_op = query_one_val(conn, "SELECT min(store_seq) FROM store_ops", [])
      latest_snapshot = query_one_val(conn, "SELECT max(snapshot_seq) FROM store_snapshots", [])

      cond do
        # If to_seq is before the snapshot, we can't reconstruct
        latest_snapshot != nil and to_seq < latest_snapshot ->
          {:error, :beyond_retention}

        # Snapshot covers this seq
        latest_snapshot != nil and to_seq >= latest_snapshot ->
          :ok

        # No snapshot, no ops = empty store
        earliest_op == nil ->
          {:error, :no_ops}

        # No snapshot, seq before earliest op
        to_seq < earliest_op ->
          {:error, :beyond_retention}

        true ->
          :ok
      end
    end) || {:error, :no_ops}
  end

  def compute_historical_value(store_id, path, to_seq) do
    state = compute_historical_state(store_id, to_seq)
    state = state || %{}

    case Map.get(state, path) do
      nil ->
        # Path may be a map root whose leaves are expanded in state.
        # Reconstruct the map from descendant paths.
        assemble_subtree_from_state(state, path)

      value ->
        value
    end
  end

  defp assemble_subtree_from_state(state, path) do
    prefix = path <> "."

    descendants =
      state
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)

    case descendants do
      [] ->
        nil

      entries ->
        map =
          Enum.reduce(entries, %{}, fn {entry_path, wrapped_value}, acc ->
            relative = String.replace_prefix(entry_path, prefix, "")
            keys = String.split(relative, ".")
            value = ValueCodec.unwrap(wrapped_value)
            put_nested(acc, keys, value)
          end)

        ValueCodec.wrap(map)
    end
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, put_nested(child, rest, value))
  end

  def compute_historical_state(store_id, to_seq) do
    with_read_conn(store_id, fn conn ->
      # Seed from snapshot if available
      {seed_state, start_seq} = load_snapshot_seed(conn, to_seq)

      # Replay ops from start_seq to to_seq
      rows =
        query_all(
          conn,
          """
            SELECT store_seq, op, path, value FROM store_ops
            WHERE store_seq > ? AND store_seq <= ? ORDER BY store_seq ASC
          """,
          [start_seq, to_seq]
        )

      Enum.reduce(rows, seed_state, fn [_seq, op, path, value_json], state ->
        op = String.to_existing_atom(op)
        value = if value_json, do: Jason.decode!(value_json)
        apply_op_to_state(state, %{op: op, path: path, value: value})
      end)
    end) || %{}
  end

  # --- Private ---

  defp load_snapshot_seed(conn, to_seq) do
    case query_one_row(conn, """
      SELECT snapshot_seq, snapshot_data FROM store_snapshots
      WHERE snapshot_seq <= ? ORDER BY snapshot_seq DESC LIMIT 1
    """, [to_seq]) do
      [seq, json] ->
        snapshot = Jason.decode!(json)

        state =
          Map.new(snapshot, fn {path, %{"value" => value, "type" => _type}} ->
            {path, value}
          end)

        {state, seq}

      nil ->
        {%{}, 0}
    end
  end

  defp resolve_historical_value(nil, nil, _), do: nil

  defp resolve_historical_value(nil, ancestor_row, segments) do
    extract_descendant_value(ancestor_row, segments)
  end

  defp resolve_historical_value([_seq, op, _path, value_json], nil, _) do
    if op == "delete", do: nil, else: Jason.decode!(value_json)
  end

  defp resolve_historical_value([d_seq, d_op, _d_path, d_val], [a_seq | _] = ancestor, segments) do
    if a_seq > d_seq do
      extract_descendant_value(ancestor, segments)
    else
      if d_op == "delete", do: nil, else: Jason.decode!(d_val)
    end
  end

  defp find_most_recent_ancestor_op(conn, segments, to_seq) when length(segments) > 1 do
    ancestor_paths =
      segments
      |> Enum.slice(0..-2//1)
      |> Enum.scan(fn seg, acc -> "#{acc}.#{seg}" end)

    placeholders = Enum.map_join(1..length(ancestor_paths), ", ", fn _ -> "?" end)

    query_one_row(
      conn,
      """
        SELECT store_seq, op, path, value FROM store_ops
        WHERE path IN (#{placeholders}) AND store_seq <= ? AND op IN ('set', 'delete')
        ORDER BY store_seq DESC LIMIT 1
      """,
      ancestor_paths ++ [to_seq]
    )
  end

  defp find_most_recent_ancestor_op(_, _, _), do: nil

  defp extract_descendant_value([_seq, "delete", _path, _val], _segments), do: nil

  defp extract_descendant_value([_seq, "set", ancestor_path, value_json], segments) do
    {:ok, ancestor_segments} = DustProtocol.Path.parse(ancestor_path)
    relative_keys = Enum.drop(segments, length(ancestor_segments))
    value = Jason.decode!(value_json) |> ValueCodec.unwrap()

    Enum.reduce_while(relative_keys, value, fn key, acc ->
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

  defp extract_descendant_value(nil, _), do: nil

  defp current_path_value(store_id, path) do
    case Sync.get_entry(store_id, path) do
      nil -> nil
      entry -> ValueCodec.wrap(entry.value)
    end
  end

  defp get_raw_entries(store_id) do
    with_read_conn(store_id, fn conn ->
      query_all(conn, "SELECT path, value FROM store_entries ORDER BY path", [])
      |> Enum.map(fn [path, json] -> {path, Jason.decode!(json)} end)
    end) || []
  end

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

  # --- Op replay for compute_historical_state ---

  defp apply_op_to_state(state, %{op: :set, path: path, value: value}) do
    state = delete_descendants_from_state(state, path)
    unwrapped = ValueCodec.unwrap(value)

    if is_map(unwrapped) and not ValueCodec.typed_value?(unwrapped) do
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
    state |> Map.delete(path) |> delete_descendants_from_state(path)
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
    state |> Enum.reject(fn {k, _v} -> String.starts_with?(k, prefix) end) |> Map.new()
  end

  # --- SQLite helpers ---

  defp with_read_conn(store_id, fun) do
    case StoreDB.read_conn(store_id) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          StoreDB.close(conn)
        end

      {:error, :not_found} ->
        nil

      {:error, _} ->
        nil
    end
  end

  defp query_one_val(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [val]} -> val
        :done -> nil
      end

    :ok = Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  defp query_one_row(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)

    result =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, row} -> row
        :done -> nil
      end

    :ok = Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  defp query_all(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = collect_rows(conn, stmt, [])
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    rows
  end

  defp collect_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
