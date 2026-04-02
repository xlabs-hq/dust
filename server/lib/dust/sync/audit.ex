defmodule Dust.Sync.Audit do
  @moduledoc "Rich filtering and pagination for store operations (audit log)."

  alias Dust.Sync.StoreDB

  @doc """
  Query ops for a store with optional filters.

  Options:
    - `:path`      — exact path or wildcard pattern (e.g. "users.*")
    - `:device_id` — filter by device
    - `:op`        — filter by op type (string or atom, e.g. "set" or :set)
    - `:since`     — DateTime or ISO8601 string; only ops inserted at or after this time
    - `:limit`     — max results (default 50)
    - `:offset`    — pagination offset (default 0)
  """
  def query_ops(store_id, opts \\ []) do
    with_read_conn(store_id, fn conn ->
      {where_clauses, params} = build_filters(opts)
      limit = opts[:limit] || 50
      offset = opts[:offset] || 0

      where_sql = if where_clauses == [], do: "", else: " AND " <> Enum.join(where_clauses, " AND ")

      sql = """
        SELECT store_seq, op, path, value, type, device_id, client_op_id, inserted_at
        FROM store_ops
        WHERE 1=1#{where_sql}
        ORDER BY store_seq DESC
        LIMIT ? OFFSET ?
      """

      query_all(conn, sql, params ++ [limit, offset])
      |> Enum.map(&row_to_op/1)
    end) || []
  end

  @doc "Count ops matching the given filters (ignores limit/offset)."
  def count_ops(store_id, opts \\ []) do
    with_read_conn(store_id, fn conn ->
      {where_clauses, params} = build_filters(opts)
      where_sql = if where_clauses == [], do: "", else: " AND " <> Enum.join(where_clauses, " AND ")

      sql = "SELECT count(*) FROM store_ops WHERE 1=1#{where_sql}"
      query_one_val(conn, sql, params) || 0
    end) || 0
  end

  defp build_filters(opts) do
    {clauses, params} = {[], []}

    {clauses, params} = maybe_add_path(clauses, params, opts[:path])
    {clauses, params} = maybe_add_device(clauses, params, opts[:device_id])
    {clauses, params} = maybe_add_op(clauses, params, opts[:op])
    {clauses, params} = maybe_add_since(clauses, params, opts[:since])

    {clauses, params}
  end

  defp maybe_add_path(clauses, params, nil), do: {clauses, params}
  defp maybe_add_path(clauses, params, ""), do: {clauses, params}

  defp maybe_add_path(clauses, params, path) do
    if String.contains?(path, "*") do
      like_pattern =
        path
        |> String.replace("%", "\\%")
        |> String.replace("_", "\\_")
        |> String.replace("**", "%%DOUBLE%%")
        |> String.replace("*", "%")
        |> String.replace("%%DOUBLE%%", "%")

      {clauses ++ ["path LIKE ?"], params ++ [like_pattern]}
    else
      {clauses ++ ["path = ?"], params ++ [path]}
    end
  end

  defp maybe_add_device(clauses, params, nil), do: {clauses, params}
  defp maybe_add_device(clauses, params, ""), do: {clauses, params}
  defp maybe_add_device(clauses, params, device_id), do: {clauses ++ ["device_id = ?"], params ++ [device_id]}

  defp maybe_add_op(clauses, params, nil), do: {clauses, params}
  defp maybe_add_op(clauses, params, ""), do: {clauses, params}
  defp maybe_add_op(clauses, params, op) when is_atom(op), do: {clauses ++ ["op = ?"], params ++ [to_string(op)]}
  defp maybe_add_op(clauses, params, op) when is_binary(op), do: {clauses ++ ["op = ?"], params ++ [op]}

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

      _ -> nil
    end
  end

  defp query_one_val(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    result = case Exqlite.Sqlite3.step(conn, stmt) do
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
