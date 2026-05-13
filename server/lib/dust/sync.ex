defmodule Dust.Sync do
  import Ecto.Query, only: [from: 2]
  alias Dust.Sync.{Writer, Rollback, StoreDB, ValueCodec}
  alias DustProtocol.Path

  @doc """
  Convert a caller-provided path into the canonical rendered slash
  form used everywhere below (SQL, materialized state, op echo,
  webhook payloads).

  Accepts:
    * a segment list — `["a", "b", "c"]` → `{:ok, "a/b/c"}`
    * a canonical rendered slash string — `"a/b/c"` → passed through
      after validation

  Returns `{:error, reason}` on invalid input. Importantly, a string
  like `"example.com"` is treated as **one segment** containing a
  literal dot — not as the legacy two-segment form. Callers that
  hold genuinely-legacy dotted strings must convert them explicitly
  via `DustProtocol.Path.LegacyDot.parse/1` before calling this.
  """
  @spec normalize_path(term()) :: {:ok, String.t()} | {:error, atom()}
  def normalize_path(path_segments) when is_list(path_segments) do
    with {:ok, segments} <- Path.from_segments(path_segments) do
      Path.render(segments)
    end
  end

  def normalize_path(path) when is_binary(path) do
    Path.normalize_rendered(path)
  end

  defp normalize_path_in_attrs(%{path: path} = attrs) do
    case normalize_path(path) do
      {:ok, rendered} -> {:ok, %{attrs | path: rendered}}
      err -> err
    end
  end

  def write(store_id, op_attrs) do
    with {:ok, op_attrs} <- normalize_path_in_attrs(op_attrs),
         :ok <- validate_if_match_attrs(op_attrs) do
      case Writer.write(store_id, op_attrs) do
        {:ok, op} ->
          notify_webhooks(store_id, op)
          {:ok, op}

        error ->
          error
      end
    end
  catch
    :exit, reason -> {:error, {:writer_unavailable, reason}}
  end

  @doc """
  Atomic multi-key write. Validates every op's `if_match` precondition
  up front, then commits all ops in a single sqlite transaction. Either
  every op is applied (each with its own `store_seq`) or none are.

  Returns `{:ok, [op_result, ...]}` on success — one element per input
  op, in the same order. Returns `{:error, reason}` on validation
  failure (no ops applied), or
  `{:error, {:conflict, %{op_index: i, path: p, current_revision: r}}}`
  if any op's `If-Match` precondition fails inside the transaction.
  """
  def batch_write(store_id, ops_attrs) when is_list(ops_attrs) do
    with {:ok, ops_attrs} <- normalize_batch_paths(ops_attrs),
         :ok <- validate_batch_attrs(ops_attrs) do
      case Writer.batch_write(store_id, ops_attrs) do
        {:ok, ops} ->
          Enum.each(ops, &notify_webhooks(store_id, &1))
          {:ok, ops}

        {:error, {:conflict, op_index, path}} ->
          {:error,
           {:conflict,
            %{op_index: op_index, path: path, current_revision: get_revision(store_id, path)}}}

        {:error, {reason, op_index, path}} ->
          {:error, {reason, %{op_index: op_index, path: path}}}

        error ->
          error
      end
    end
  catch
    :exit, reason -> {:error, {:writer_unavailable, reason}}
  end

  defp normalize_batch_paths(ops_attrs) do
    ops_attrs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      case normalize_path_in_attrs(attrs) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {reason, %{op_index: index}}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp validate_batch_attrs(ops_attrs) do
    Enum.reduce_while(ops_attrs, {:ok, 0}, fn attrs, {:ok, index} ->
      case validate_if_match_attrs(attrs) do
        :ok -> {:cont, {:ok, index + 1}}
        {:error, reason} -> {:halt, {:error, {reason, %{op_index: index, path: attrs[:path]}}}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp get_revision(store_id, path) do
    case get_entry(store_id, path) do
      %{seq: seq} -> seq
      _ -> nil
    end
  end

  # Transport-agnostic CAS preconditions. Both the Phoenix channel and the
  # HTTP controller route writes through `Sync.write/2`, so these two gates
  # (unsupported op, multi-leaf dict value) must live here to preserve a
  # consistent error taxonomy across transports. The channel layer enforces
  # an additional transport-specific `capver >= 2` gate before calling us.
  defp validate_if_match_attrs(attrs) do
    case fetch_if_match(attrs) do
      nil ->
        :ok

      _if_match ->
        op = attrs[:op] || attrs["op"]
        value = attrs[:value] || attrs["value"]

        cond do
          op not in [:set, :delete] ->
            {:error, :if_match_unsupported_op}

          op == :set and is_map(value) and not ValueCodec.typed_value?(value) ->
            {:error, :if_match_multi_leaf}

          true ->
            :ok
        end
    end
  end

  defp fetch_if_match(attrs) do
    attrs[:if_match] || attrs["if_match"]
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
    with {:ok, rendered} <- normalize_path(path) do
      with_read_conn(store_id, fn conn ->
        case query_one_row(
               conn,
               "SELECT path, value, type, seq FROM store_entries WHERE path = ?",
               [rendered]
             ) do
          [_path, json, type, seq] ->
            value = json |> Jason.decode!() |> ValueCodec.unwrap()
            %{path: rendered, value: value, type: type, seq: seq}

          nil ->
            assemble_subtree(conn, rendered)
        end
      end)
    else
      _ -> nil
    end
  end

  defp assemble_subtree(conn, path) do
    {:ok, prefix_segments} = Path.parse_rendered(path)
    {:ok, prefix} = Path.render_descendant_prefix(prefix_segments)

    rows =
      query_all(
        conn,
        ~s|SELECT path, value, type, seq FROM store_entries WHERE path LIKE ? ESCAPE '\\' ORDER BY path|,
        ["#{escape_like(prefix)}%"]
      )

    case rows do
      [] ->
        nil

      entries ->
        max_seq = entries |> Enum.map(fn [_, _, _, seq] -> seq end) |> Enum.max()
        prefix_len = length(prefix_segments)

        map =
          Enum.reduce(entries, %{}, fn [entry_path, json, _type, _seq], acc ->
            {:ok, entry_segments} = Path.parse_rendered(entry_path)
            # Drop the ancestor prefix segments to get the path
            # *inside* the assembled subtree. These segments are the
            # nesting keys for `put_nested/3`.
            relative_keys = Enum.drop(entry_segments, prefix_len)
            value = json |> Jason.decode!() |> ValueCodec.unwrap()
            put_nested(acc, relative_keys, value)
          end)

        %{path: path, value: map, type: "map", seq: max_seq}
    end
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, put_nested(child, rest, value))
  end

  @spec get_many_entries(binary(), [String.t()]) :: %{entries: map(), missing: [String.t()]}
  def get_many_entries(store_id, paths) when is_list(paths) do
    # Each input may be dotted (legacy) or slash (canonical). Keep
    # both forms so we can report `missing` keyed by the *original*
    # input shape the caller asked about, while the SQL IN clause
    # uses canonical rendered keys.
    pairs =
      paths
      |> Enum.uniq()
      |> Enum.map(fn p ->
        case normalize_path(p) do
          {:ok, rendered} -> {p, rendered}
          _ -> {p, nil}
        end
      end)

    {valid_pairs, invalid_originals} =
      Enum.split_with(pairs, fn {_orig, rendered} -> rendered != nil end)

    invalid = Enum.map(invalid_originals, fn {orig, _} -> orig end)

    if valid_pairs == [] do
      %{entries: %{}, missing: invalid}
    else
      rendered_to_orig =
        Enum.into(valid_pairs, %{}, fn {orig, rendered} -> {rendered, orig} end)

      rendered_paths = Map.keys(rendered_to_orig)

      result =
        with_read_conn(store_id, fn conn ->
          placeholders = Enum.map_join(rendered_paths, ", ", fn _ -> "?" end)
          sql = "SELECT path, value, type, seq FROM store_entries WHERE path IN (#{placeholders})"
          rows = query_all(conn, sql, rendered_paths)

          entries =
            Enum.reduce(rows, %{}, fn [path, json, type, seq], acc ->
              value = json |> Jason.decode!() |> ValueCodec.unwrap()
              # Echo back the canonical (rendered) path as the key.
              Map.put(acc, path, %{value: value, type: type, seq: seq})
            end)

          found_rendered = Map.keys(entries)
          missing_rendered = rendered_paths -- found_rendered
          # Map missing back to whatever the caller passed in.
          missing = Enum.map(missing_rendered, &Map.fetch!(rendered_to_orig, &1)) ++ invalid
          %{entries: entries, missing: missing}
        end)

      result || %{entries: %{}, missing: paths}
    end
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

    with {:ok, pattern} <- normalize_pattern(pattern),
         :ok <- validate_select_pattern(select, pattern) do
      matched = collect_matches(store_id, pattern, order, cursor, limit)

      {page_rows, next_cursor} = take_with_cursor(matched, limit)
      items = project_rows(page_rows, select, pattern, order)

      {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  @doc """
  Convert a caller-provided glob pattern into canonical slash-rendered
  form. The input must already be canonical — wildcards `*` and `**`
  must be expressed against slash separators (`"posts/*"`, `"users/**"`).

  Legacy dotted patterns (`"posts.*"`) are not accepted; callers must
  convert explicitly.
  """
  @spec normalize_pattern(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def normalize_pattern("**"), do: {:ok, "**"}

  def normalize_pattern(pattern) when is_binary(pattern) do
    case DustProtocol.Glob.compile(pattern) do
      {:ok, _} -> {:ok, pattern}
      err -> err
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

    # Compile the pattern once per chunk and parse each row's path
    # into segments. Both sides are slash-canonical at this point.
    compiled = DustProtocol.Glob.compile!(pattern)

    matches =
      Enum.filter(rows, fn [path, _json, _type, _seq] ->
        case Path.parse_rendered(path) do
          {:ok, segs} -> DustProtocol.Glob.match?(compiled, segs)
          _ -> false
        end
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

  @doc """
  Lexicographic range read over a store's entries in `[from, to)`.

  Returns `{:ok, %{items: items, next_cursor: cursor | nil}}` or
  `{:error, :unsupported_select}` when called with `select: :prefixes`
  (prefix projection is not meaningful for raw ranges).

  Options:
    * `:limit`  — clamped to 1..1000 (default 50)
    * `:order`  — `:asc` (default) or `:desc`
    * `:select` — `:entries` (default) or `:keys` (`:prefixes` is rejected)
    * `:after`  — opaque cursor (path string); continues strictly past it
  """
  @spec range_entries(binary(), String.t(), String.t(), keyword()) ::
          {:ok, %{items: list(), next_cursor: String.t() | nil}}
          | {:error, :unsupported_select}
  def range_entries(store_id, from, to, opts \\ [])
      when is_binary(from) and is_binary(to) do
    case Keyword.get(opts, :select, :entries) do
      :prefixes ->
        {:error, :unsupported_select}

      select when select in [:entries, :keys] ->
        with {:ok, from} <- normalize_path(from),
             {:ok, to} <- normalize_path(to) do
          limit = opts |> Keyword.get(:limit, @enum_default_limit) |> clamp_limit()
          order = Keyword.get(opts, :order, :asc)
          cursor = Keyword.get(opts, :after)

          result =
            with_read_conn(store_id, fn conn ->
              rows = fetch_range_rows(conn, from, to, cursor, order, limit + 1)
              {page_rows, next_cursor} = take_with_cursor(rows, limit)
              items = project_rows(page_rows, select, nil, order)
              %{items: items, next_cursor: next_cursor}
            end) || %{items: [], next_cursor: nil}

          {:ok, result}
        end
    end
  end

  # Build a single-shot SQL range query over `[from, to)` with optional
  # keyset cursor. No post-filtering is needed — every row in the range
  # is a match — so `LIMIT limit+1` is sufficient for cursor detection.
  defp fetch_range_rows(conn, from, to, cursor, order, fetch_limit) do
    {cursor_clause, cursor_params} =
      case cursor do
        nil ->
          {"", []}

        c when is_binary(c) ->
          op = if order == :asc, do: ">", else: "<"
          {" AND path #{op} ?", [c]}
      end

    order_sql = if order == :asc, do: "ASC", else: "DESC"

    sql =
      "SELECT path, value, type, seq FROM store_entries " <>
        "WHERE path >= ? AND path < ?" <>
        cursor_clause <>
        " ORDER BY path " <>
        order_sql <>
        " LIMIT ?"

    params = [from, to] ++ cursor_params ++ [fetch_limit]
    query_all(conn, sql, params)
  end

  defp clamp_limit(n) when is_integer(n) and n < 1, do: 1
  defp clamp_limit(n) when is_integer(n) and n > @enum_max_limit, do: @enum_max_limit
  defp clamp_limit(n) when is_integer(n), do: n
  defp clamp_limit(_), do: @enum_default_limit

  defp validate_select_pattern(:prefixes, "**"), do: :ok

  defp validate_select_pattern(:prefixes, pattern) when is_binary(pattern) do
    if String.ends_with?(pattern, "/**"),
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

  @doc """
  Escape a rendered path so it can be safely bound as a SQL `LIKE`
  pattern. Use together with `LIKE ? ESCAPE '\\\\'` so literal `%` and
  `_` inside a segment can't act as wildcards.
  """
  def escape_like(literal) do
    literal
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # Return the literal prefix of a (canonical, slash-rendered) glob
  # pattern — everything before the first segment containing `*` or
  # `**`. Includes the trailing slash if non-empty.
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
    # Pattern ends in `/**`; strip the wildcard, keep the literal
    # ancestor segments + trailing `/`.
    String.replace_suffix(pattern, "**", "")
  end

  # `literal` is either "" or ends with "/".
  defp extract_prefix(path, "") do
    case String.split(path, "/", parts: 2) do
      [head | _] -> head
      _ -> nil
    end
  end

  defp extract_prefix(path, literal) do
    if String.starts_with?(path, literal) do
      rest = binary_part(path, byte_size(literal), byte_size(path) - byte_size(literal))

      case String.split(rest, "/", parts: 2) do
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
