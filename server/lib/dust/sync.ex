defmodule Dust.Sync do
  alias Dust.Sync.{Writer, Rollback, StoreDB, ValueCodec}

  def write(store_id, op_attrs) do
    Writer.write(store_id, op_attrs)
  catch
    :exit, reason -> {:error, {:writer_unavailable, reason}}
  end

  def get_entry(store_id, path) do
    with_read_conn(store_id, fn conn ->
      case query_one_row(conn, "SELECT path, value, type, seq FROM store_entries WHERE path = ?", [path]) do
        [_path, json, type, seq] ->
          value = json |> Jason.decode!() |> ValueCodec.unwrap()
          %{path: path, value: value, type: type, seq: seq}

        nil ->
          assemble_subtree(conn, path)
      end
    end)
  end

  defp assemble_subtree(conn, path) do
    prefix = path <> "."
    rows = query_all(conn, "SELECT path, value, type, seq FROM store_entries WHERE path LIKE ? ORDER BY path", ["#{prefix}%"])

    case rows do
      [] ->
        nil

      entries ->
        max_seq = entries |> Enum.map(fn [_, _, _, seq] -> seq end) |> Enum.max()

        map =
          Enum.reduce(entries, %{}, fn [entry_path, json, _type, _seq], acc ->
            relative = String.replace_prefix(entry_path, prefix, "")
            keys = String.split(relative, ".")
            value = json |> Jason.decode!() |> ValueCodec.unwrap()
            put_nested(acc, keys, value)
          end)

        %{path: path, value: map, type: "map", seq: max_seq}
    end
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, put_nested(child, rest, value))
  end

  def get_all_entries(store_id) do
    with_read_conn(store_id, fn conn ->
      query_all(conn, "SELECT path, value, type, seq FROM store_entries ORDER BY path", [])
      |> Enum.map(fn [path, json, type, seq] ->
        %{path: path, value: json |> Jason.decode!() |> ValueCodec.unwrap(), type: type, seq: seq}
      end)
    end) || []
  end

  @catch_up_batch_size 1000

  def get_ops_since(store_id, since_seq, opts \\ []) do
    limit = Keyword.get(opts, :limit, @catch_up_batch_size)

    with_read_conn(store_id, fn conn ->
      query_all(conn, """
        SELECT store_seq, op, path, value, type, device_id, client_op_id
        FROM store_ops WHERE store_seq > ? ORDER BY store_seq ASC LIMIT ?
      """, [since_seq, limit])
      |> Enum.map(&row_to_op/1)
    end) || []
  end

  def current_seq(store_id) do
    with_read_conn(store_id, fn conn ->
      ops_seq = query_one_int(conn, "SELECT max(store_seq) FROM store_ops")
      snap_seq = query_one_int(conn, "SELECT max(snapshot_seq) FROM store_snapshots")
      max(ops_seq, snap_seq)
    end) || 0
  end

  def earliest_op_seq(store_id) do
    with_read_conn(store_id, fn conn ->
      query_one_val(conn, "SELECT min(store_seq) FROM store_ops", [])
    end)
  end

  def get_entries_page(store_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    with_read_conn(store_id, fn conn ->
      query_all(conn, "SELECT path, value, type, seq FROM store_entries ORDER BY path LIMIT ? OFFSET ?", [limit, offset])
      |> Enum.map(fn [path, json, type, seq] ->
        %{path: path, value: json |> Jason.decode!() |> ValueCodec.unwrap(), type: type, seq: seq}
      end)
    end) || []
  end

  def get_ops_page(store_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    with_read_conn(store_id, fn conn ->
      query_all(conn, """
        SELECT store_seq, op, path, value, type, device_id, client_op_id, inserted_at
        FROM store_ops ORDER BY store_seq DESC LIMIT ? OFFSET ?
      """, [limit, offset])
      |> Enum.map(&row_to_op_with_time/1)
    end) || []
  end

  def has_file_ref?(store_id, hash) do
    with_read_conn(store_id, fn conn ->
      case query_one_val(conn, """
        SELECT 1 FROM store_entries
        WHERE type = 'file' AND json_extract(value, '$.hash') = ?
        LIMIT 1
      """, [hash]) do
        1 -> true
        _ -> false
      end
    end) || false
  end

  def get_latest_snapshot(store_id) do
    with_read_conn(store_id, fn conn ->
      case query_one_row(conn, """
        SELECT snapshot_seq, snapshot_data FROM store_snapshots
        ORDER BY snapshot_seq DESC LIMIT 1
      """, []) do
        [seq, json] ->
          %{snapshot_seq: seq, snapshot_data: Jason.decode!(json)}

        nil ->
          nil
      end
    end)
  end

  def entry_count(store_id) do
    with_read_conn(store_id, fn conn ->
      query_one_int(conn, "SELECT count(*) FROM store_entries")
    end) || 0
  end

  def rollback(store_id, path, to_seq) do
    Rollback.rollback_path(store_id, path, to_seq)
  end

  def rollback(store_id, to_seq) do
    Rollback.rollback_store(store_id, to_seq)
  end

  # --- SQLite read connection helper ---

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

  defp row_to_op([store_seq, op, path, value_json, type, device_id, client_op_id]) do
    value = if value_json, do: Jason.decode!(value_json)

    %{
      store_seq: store_seq,
      op: String.to_existing_atom(op),
      path: path,
      value: value,
      type: type,
      device_id: device_id,
      client_op_id: client_op_id
    }
  end

  defp row_to_op_with_time([store_seq, op, path, value_json, type, device_id, client_op_id, inserted_at]) do
    value = if value_json, do: Jason.decode!(value_json)

    %{
      store_seq: store_seq,
      op: String.to_existing_atom(op),
      path: path,
      value: value,
      type: type,
      device_id: device_id,
      client_op_id: client_op_id,
      inserted_at: inserted_at
    }
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

  defp query_one_int(conn, sql) do
    case query_one_val(conn, sql, []) do
      nil -> 0
      val when is_integer(val) -> val
      _ -> 0
    end
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
