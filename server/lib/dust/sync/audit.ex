defmodule Dust.Sync.Audit do
  @moduledoc """
  Rich filtering and pagination for store operations (audit log).

  ## Scalability note

  Wildcard filters use SQL LIKE as a coarse candidate filter and then
  post-filter rows in Elixir via `DustProtocol.Glob.match?/2` to enforce
  segment-aware semantics (see `query_ops/2`). For stores with very
  large op logs the full candidate set is materialised before
  pagination, which can become expensive. The long-term fix is to
  walk SQLite in chunks the way `Dust.Sync.enum_entries/3` does
  (`@enum_chunk_size` in `lib/dust/sync.ex`) and accumulate matches
  until the requested page is filled. For now the current xlabs-scale
  load makes this a P3 — revisit before opening the audit endpoint to
  high-volume tenants.
  """

  alias Dust.Sync.StoreDB
  alias DustProtocol.Glob
  alias DustProtocol.Path, as: DPath

  @doc """
  Query ops for a store with optional filters.

  Options:
    - `:path`      — exact path or segment-aware wildcard pattern
                     (e.g. `"users/*"`, `"users/**"`)
    - `:device_id` — filter by device
    - `:op`        — filter by op type (string or atom, e.g. "set" or :set)
    - `:since`     — DateTime or ISO8601 string; only ops inserted at or
                     after this time
    - `:limit`     — max results (default 50)
    - `:offset`    — pagination offset (default 0)
  """
  def query_ops(store_id, opts \\ []) do
    with_read_conn(store_id, fn conn ->
      {where_clauses, params, glob} = build_filters(opts)
      limit = opts[:limit] || 50
      offset = opts[:offset] || 0

      where_sql =
        if where_clauses == [], do: "", else: " AND " <> Enum.join(where_clauses, " AND ")

      if glob do
        # Wildcard filter: SQL LIKE is only a coarse candidate filter
        # (it doesn't respect segment boundaries). Pull the candidate
        # set in store_seq DESC order, then apply the segment-aware
        # glob match in Elixir before paginating.
        sql = """
          SELECT store_seq, op, path, value, type, device_id, client_op_id, inserted_at
          FROM store_ops
          WHERE 1=1#{where_sql}
          ORDER BY store_seq DESC
        """

        query_all(conn, sql, params)
        |> Enum.map(&row_to_op/1)
        |> Enum.filter(&glob_match_op?(&1, glob))
        |> Enum.drop(offset)
        |> Enum.take(limit)
      else
        sql = """
          SELECT store_seq, op, path, value, type, device_id, client_op_id, inserted_at
          FROM store_ops
          WHERE 1=1#{where_sql}
          ORDER BY store_seq DESC
          LIMIT ? OFFSET ?
        """

        query_all(conn, sql, params ++ [limit, offset])
        |> Enum.map(&row_to_op/1)
      end
    end) || []
  end

  @doc "Count ops matching the given filters (ignores limit/offset)."
  def count_ops(store_id, opts \\ []) do
    with_read_conn(store_id, fn conn ->
      {where_clauses, params, glob} = build_filters(opts)

      where_sql =
        if where_clauses == [], do: "", else: " AND " <> Enum.join(where_clauses, " AND ")

      if glob do
        # See query_ops/2 for why the precise count walks the candidate
        # rows in Elixir rather than `SELECT count(*)`.
        sql = "SELECT path FROM store_ops WHERE 1=1#{where_sql}"

        query_all(conn, sql, params)
        |> Enum.count(fn [path] -> glob_match_path?(path, glob) end)
      else
        sql = "SELECT count(*) FROM store_ops WHERE 1=1#{where_sql}"
        query_one_val(conn, sql, params) || 0
      end
    end) || 0
  end

  defp build_filters(opts) do
    {clauses, params, glob} = {[], [], nil}

    {clauses, params, glob} = maybe_add_path(clauses, params, glob, opts[:path])
    {clauses, params} = maybe_add_device(clauses, params, opts[:device_id])
    {clauses, params} = maybe_add_op(clauses, params, opts[:op])
    {clauses, params} = maybe_add_since(clauses, params, opts[:since])

    {clauses, params, glob}
  end

  defp maybe_add_path(clauses, params, glob, nil), do: {clauses, params, glob}
  defp maybe_add_path(clauses, params, glob, ""), do: {clauses, params, glob}

  defp maybe_add_path(clauses, params, _glob, path) do
    if String.contains?(path, "*") do
      case Glob.compile(path) do
        {:ok, compiled} ->
          prefix = literal_prefix_of_pattern(path)

          if prefix == "" do
            {clauses, params, compiled}
          else
            like = escape_like(prefix) <> "%"
            {clauses ++ ["path LIKE ? ESCAPE '\\'"], params ++ [like], compiled}
          end

        _ ->
          {clauses ++ ["path = ?"], params ++ [path], nil}
      end
    else
      normalized =
        case Dust.Sync.normalize_path(path) do
          {:ok, p} -> p
          _ -> path
        end

      {clauses ++ ["path = ?"], params ++ [normalized], nil}
    end
  end

  defp glob_match_op?(%{path: path}, glob), do: glob_match_path?(path, glob)

  defp glob_match_path?(path, glob) do
    case DPath.parse_rendered(path) do
      {:ok, segs} -> Glob.match?(glob, segs)
      _ -> false
    end
  end

  # Literal slash-rendered prefix of a glob pattern (everything before
  # the first segment that contains a wildcard). Includes the trailing
  # `/` when non-empty so the LIKE prefix stops at a segment boundary.
  defp literal_prefix_of_pattern(pattern) do
    segments = String.split(pattern, "/")

    literal =
      Enum.take_while(segments, fn seg ->
        seg != "*" and seg != "**" and not String.contains?(seg, "*")
      end)

    case literal do
      [] -> ""
      segs -> Enum.join(segs, "/") <> "/"
    end
  end

  defp escape_like(literal) do
    literal
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp maybe_add_device(clauses, params, nil), do: {clauses, params}
  defp maybe_add_device(clauses, params, ""), do: {clauses, params}

  defp maybe_add_device(clauses, params, device_id),
    do: {clauses ++ ["device_id = ?"], params ++ [device_id]}

  defp maybe_add_op(clauses, params, nil), do: {clauses, params}
  defp maybe_add_op(clauses, params, ""), do: {clauses, params}

  defp maybe_add_op(clauses, params, op) when is_atom(op),
    do: {clauses ++ ["op = ?"], params ++ [to_string(op)]}

  defp maybe_add_op(clauses, params, op) when is_binary(op),
    do: {clauses ++ ["op = ?"], params ++ [op]}

  defp maybe_add_since(clauses, params, nil), do: {clauses, params}

  defp maybe_add_since(clauses, params, %DateTime{} = since) do
    {clauses ++ ["inserted_at >= ?"], params ++ [DateTime.to_iso8601(since)]}
  end

  defp maybe_add_since(clauses, params, since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> {clauses ++ ["inserted_at >= ?"], params ++ [DateTime.to_iso8601(dt)]}
      _ -> {clauses, params}
    end
  end

  defp row_to_op([store_seq, op, path, value_json, type, device_id, client_op_id, inserted_at]) do
    %{
      store_seq: store_seq,
      op: String.to_existing_atom(op),
      path: path,
      value: if(value_json, do: Jason.decode!(value_json)),
      type: type,
      device_id: device_id,
      client_op_id: client_op_id,
      inserted_at: inserted_at
    }
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

      _ ->
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
