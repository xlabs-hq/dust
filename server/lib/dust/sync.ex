defmodule Dust.Sync do
  import Ecto.Query, only: [from: 2]
  alias Dust.Sync.{Writer, Rollback, StoreDB, ValueCodec}

  def write(store_id, op_attrs) do
    case Writer.write(store_id, op_attrs) do
      {:ok, op} ->
        notify_webhooks(store_id, op)
        {:ok, op}

      error ->
        error
    end
  catch
    :exit, reason -> {:error, {:writer_unavailable, reason}}
  end

  defp notify_webhooks(store_id, op) do
    case store_full_name(store_id) do
      {:ok, full_name} ->
        value = materialize_webhook_value(op)

        event = %{
          "event" => "entry.changed",
          "store" => full_name,
          "store_seq" => op.store_seq,
          "op" => to_string(op.op),
          "path" => op.path,
          "value" => value,
          "device_id" => op.device_id,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Dust.Webhooks.enqueue_deliveries(store_id, event)

      _ ->
        :ok
    end
  end

  defp store_full_name(store_id) do
    case Dust.Repo.one(
           from(s in Dust.Stores.Store,
             join: o in assoc(s, :organization),
             where: s.id == ^store_id,
             select: {o.slug, s.name}
           )
         ) do
      {org_slug, store_name} -> {:ok, "#{org_slug}/#{store_name}"}
      nil -> :error
    end
  end

  defp materialize_webhook_value(op) do
    case Map.get(op, :materialized_value) do
      nil -> ValueCodec.unwrap(op.value)
      mat -> mat
    end
  end

  def get_entry(store_id, path) do
    with_read_conn(store_id, fn conn ->
      case query_one_row(
             conn,
             "SELECT path, value, type, seq FROM store_entries WHERE path = ?",
             [path]
           ) do
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

    rows =
      query_all(
        conn,
        "SELECT path, value, type, seq FROM store_entries WHERE path LIKE ? ORDER BY path",
        ["#{prefix}%"]
      )

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
      query_all(
        conn,
        """
          SELECT store_seq, op, path, value, type, device_id, client_op_id, inserted_at
          FROM store_ops WHERE store_seq > ? ORDER BY store_seq ASC LIMIT ?
        """,
        [since_seq, limit]
      )
      |> Enum.map(&row_to_op_with_time/1)
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
      query_all(
        conn,
        "SELECT path, value, type, seq FROM store_entries ORDER BY path LIMIT ? OFFSET ?",
        [limit, offset]
      )
      |> Enum.map(fn [path, json, type, seq] ->
        %{path: path, value: json |> Jason.decode!() |> ValueCodec.unwrap(), type: type, seq: seq}
      end)
    end) || []
  end

  @enum_default_limit 50
  @enum_max_limit 1000

  @doc """
  Paginated enum over a store's entries. Mirrors `Dust.enum/3` in the SDK
  but reads from the authoritative server storage.

  Returns `{:ok, %{items: items, next_cursor: cursor | nil}}`.

  Options:
    * `:limit`  — clamped to 1..1000 (default 50)
    * `:order`  — `:asc` (default) or `:desc`
    * `:select` — `:entries` (default), `:keys`, or `:prefixes`
    * `:after`  — opaque cursor (path string)
  """
  def enum_entries(store_id, pattern, opts \\ []) when is_binary(pattern) do
    limit = opts |> Keyword.get(:limit, @enum_default_limit) |> clamp_limit()
    order = Keyword.get(opts, :order, :asc)
    select = Keyword.get(opts, :select, :entries)
    cursor = Keyword.get(opts, :after)

    with :ok <- validate_select_pattern(select, pattern) do
      matched = collect_matches(store_id, pattern, order, cursor, limit)

      {page_rows, next_cursor} = take_with_cursor(matched, limit)
      items = project_rows(page_rows, select, pattern, order)

      {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  # Chunk size used to walk raw rows when the glob is narrower than the
  # LIKE prefix. Not configurable for Phase 1.
  @enum_chunk_size 500

  # Fetch raw rows in chunks and filter through the glob matcher until we
  # have at least `limit + 1` matches (to detect the next page cursor) or
  # the raw source is exhausted. Cursor advances through raw rows so that
  # unmatched rows between matches are naturally skipped on subsequent
  # chunks, but the cursor *returned to the caller* upstream is the path
  # of the last returned match (not the last raw row).
  defp collect_matches(store_id, pattern, order, cursor, limit) do
    do_collect_matches(store_id, pattern, order, cursor, limit, [])
  end

  defp do_collect_matches(store_id, pattern, order, cursor, limit, acc) do
    rows = fetch_entries_chunk(store_id, pattern, order, cursor, @enum_chunk_size)

    matches =
      Enum.filter(rows, fn [path, _json, _type, _seq] ->
        Dust.Glob.match?(path, pattern)
      end)

    all = acc ++ matches

    cond do
      length(all) > limit ->
        Enum.take(all, limit + 1)

      length(rows) < @enum_chunk_size ->
        all

      true ->
        [last_raw_path | _] = List.last(rows)
        do_collect_matches(store_id, pattern, order, last_raw_path, limit, all)
    end
  end

  defp clamp_limit(n) when is_integer(n) and n < 1, do: 1
  defp clamp_limit(n) when is_integer(n) and n > @enum_max_limit, do: @enum_max_limit
  defp clamp_limit(n) when is_integer(n), do: n
  defp clamp_limit(_), do: @enum_default_limit

  defp validate_select_pattern(:prefixes, "**"), do: :ok

  defp validate_select_pattern(:prefixes, pattern) when is_binary(pattern) do
    if String.ends_with?(pattern, ".**"),
      do: :ok,
      else: {:error, :invalid_pattern_for_prefixes}
  end

  defp validate_select_pattern(_select, _pattern), do: :ok

  # Fetch a chunk of raw rows from store_entries using a keyset query
  # filtered by the pattern's literal prefix (if any). The LIKE clause
  # escapes `\`, `%`, and `_` in the literal prefix so that paths
  # containing SQL LIKE wildcards are not misinterpreted.
  defp fetch_entries_chunk(store_id, pattern, order, cursor, fetch_limit) do
    literal = literal_prefix_of_pattern(pattern)

    {where_parts, params} = {[], []}

    {where_parts, params} =
      case cursor do
        nil ->
          {where_parts, params}

        c when is_binary(c) ->
          op = if order == :asc, do: ">", else: "<"
          {["path #{op} ?" | where_parts], [c | params]}
      end

    {where_parts, params} =
      case literal do
        "" ->
          {where_parts, params}

        prefix ->
          escaped = escape_like(prefix)
          {[~s|path LIKE ? ESCAPE '\\'| | where_parts], ["#{escaped}%" | params]}
      end

    # where_parts and params were both prepended (reverse chronological order).
    # Reverse both so the i-th clause binds to the i-th param.
    ordered_where = Enum.reverse(where_parts)
    ordered_params = Enum.reverse(params)

    where_sql =
      case ordered_where do
        [] -> ""
        parts -> "WHERE " <> Enum.join(parts, " AND ")
      end

    order_sql = if order == :asc, do: "ASC", else: "DESC"

    sql =
      "SELECT path, value, type, seq FROM store_entries #{where_sql} " <>
        "ORDER BY path #{order_sql} LIMIT ?"

    params = ordered_params ++ [fetch_limit]

    with_read_conn(store_id, fn conn ->
      query_all(conn, sql, params)
    end) || []
  end

  defp escape_like(literal) do
    literal
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # Return the literal prefix of a glob pattern — everything before the first
  # segment containing `*` or `**`. Includes the trailing dot if non-empty.
  defp literal_prefix_of_pattern(pattern) do
    segments = String.split(pattern, ".")

    literal =
      Enum.take_while(segments, fn seg ->
        seg != "*" and seg != "**" and not String.contains?(seg, "*")
      end)

    case literal do
      [] -> ""
      segs -> Enum.join(segs, ".") <> "."
    end
  end

  defp take_with_cursor(rows, limit) do
    case Enum.split(rows, limit) do
      {page, []} ->
        {page, nil}

      {page, [_next | _]} ->
        [_path, _json, _type, _seq] = last_row = List.last(page)
        cursor = hd(last_row)
        {page, cursor}
    end
  end

  defp project_rows(rows, :entries, _pattern, _order) do
    Enum.map(rows, fn [path, json, type, seq] ->
      value = json |> Jason.decode!() |> ValueCodec.unwrap()
      %{path: path, value: value, type: type, revision: seq}
    end)
  end

  defp project_rows(rows, :keys, _pattern, _order) do
    Enum.map(rows, fn [path, _json, _type, _seq] -> path end)
  end

  defp project_rows(rows, :prefixes, pattern, order) do
    literal = prefixes_literal(pattern)

    rows
    |> Enum.map(fn [path, _json, _type, _seq] -> extract_prefix(path, literal) end)
    |> Enum.reject(&is_nil/1)
    |> dedupe_and_sort(order)
  end

  defp prefixes_literal("**"), do: ""

  defp prefixes_literal(pattern) do
    # Pattern ends in ".**"; strip it, keep the literal segment + trailing dot.
    String.replace_suffix(pattern, "**", "")
  end

  # literal is either "" or ends with "."
  defp extract_prefix(path, "") do
    case String.split(path, ".", parts: 2) do
      [head | _] -> head
      _ -> nil
    end
  end

  defp extract_prefix(path, literal) do
    if String.starts_with?(path, literal) do
      rest = binary_part(path, byte_size(literal), byte_size(path) - byte_size(literal))

      case String.split(rest, ".", parts: 2) do
        [head | _] when head != "" -> literal <> head
        _ -> nil
      end
    else
      nil
    end
  end

  defp dedupe_and_sort(list, order) do
    sorted = list |> Enum.uniq() |> Enum.sort()
    if order == :desc, do: Enum.reverse(sorted), else: sorted
  end

  def get_ops_page(store_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    with_read_conn(store_id, fn conn ->
      query_all(
        conn,
        """
          SELECT store_seq, op, path, value, type, device_id, client_op_id, inserted_at
          FROM store_ops ORDER BY store_seq DESC LIMIT ? OFFSET ?
        """,
        [limit, offset]
      )
      |> Enum.map(&row_to_op_with_time/1)
    end) || []
  end

  def has_file_ref?(store_id, hash) do
    with_read_conn(store_id, fn conn ->
      case query_one_val(
             conn,
             """
               SELECT 1 FROM store_entries
               WHERE type = 'file' AND json_extract(value, '$.hash') = ?
               LIMIT 1
             """,
             [hash]
           ) do
        1 -> true
        _ -> false
      end
    end) || false
  end

  def get_latest_snapshot(store_id) do
    with_read_conn(store_id, fn conn ->
      case query_one_row(
             conn,
             """
               SELECT snapshot_seq, snapshot_data, inserted_at FROM store_snapshots
               ORDER BY snapshot_seq DESC LIMIT 1
             """,
             []
           ) do
        [seq, json, inserted_at] ->
          %{snapshot_seq: seq, snapshot_data: Jason.decode!(json), inserted_at: inserted_at}

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

  defp row_to_op_with_time([
         store_seq,
         op,
         path,
         value_json,
         type,
         device_id,
         client_op_id,
         inserted_at
       ]) do
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
