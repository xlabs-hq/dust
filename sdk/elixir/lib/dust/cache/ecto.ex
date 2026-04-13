if Code.ensure_loaded?(Ecto.Query) do
  defmodule Dust.Cache.Ecto do
    @behaviour Dust.Cache

    import Ecto.Query

    alias Dust.Cache.Ecto.CacheEntry

    @seq_sentinel_path "_dust:last_seq"

    @impl Dust.Cache
    def read(repo, store, path) do
      query =
        from(c in CacheEntry,
          where: c.store == ^store and c.path == ^path,
          select: c.value
        )

      case repo.one(query) do
        nil -> :miss
        json -> {:ok, Jason.decode!(json)}
      end
    end

    @impl Dust.Cache
    def read_entry(repo, store, path) do
      query =
        from(c in CacheEntry,
          where: c.store == ^store and c.path == ^path,
          select: {c.value, c.type, c.seq}
        )

      case repo.one(query) do
        nil -> :miss
        {json, type, seq} -> {:ok, {Jason.decode!(json), type, seq}}
      end
    end

    @impl Dust.Cache
    def read_many(repo, store, paths) do
      unique_paths = Enum.uniq(paths)

      if unique_paths == [] do
        %{}
      else
        query =
          from(c in CacheEntry,
            where: c.store == ^store and c.path in ^unique_paths,
            select: {c.path, c.value, c.type, c.seq}
          )

        repo.all(query)
        |> Enum.reduce(%{}, fn {path, json, type, seq}, acc ->
          Map.put(acc, path, {Jason.decode!(json), type, seq})
        end)
      end
    end

    @impl Dust.Cache
    def read_all(repo, store, pattern) do
      compiled = Dust.Protocol.Glob.compile(pattern)

      query =
        from(c in CacheEntry,
          where: c.store == ^store and c.path != ^@seq_sentinel_path,
          select: {c.path, c.value}
        )

      repo.all(query)
      |> Enum.filter(fn {path, _} ->
        Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
      end)
      |> Enum.map(fn {path, json} -> {path, Jason.decode!(json)} end)
    end

    @impl Dust.Cache
    def write(repo, store, path, value, type, seq) do
      entry = %{
        store: store,
        path: path,
        value: Jason.encode!(value),
        type: type,
        seq: seq
      }

      repo.insert_all(CacheEntry, [entry],
        on_conflict: [set: [value: entry.value, type: entry.type, seq: entry.seq]],
        conflict_target: [:store, :path]
      )

      update_seq_sentinel(repo, store, seq)
      :ok
    end

    @impl Dust.Cache
    def write_batch(repo, store, entries) do
      rows =
        Enum.map(entries, fn {path, value, type, seq} ->
          %{
            store: store,
            path: path,
            value: Jason.encode!(value),
            type: type,
            seq: seq
          }
        end)

      max_seq =
        Enum.reduce(rows, 0, fn row, acc ->
          repo.insert_all(CacheEntry, [row],
            on_conflict: [set: [value: row.value, type: row.type, seq: row.seq]],
            conflict_target: [:store, :path]
          )

          max(acc, row.seq)
        end)

      if max_seq > 0, do: update_seq_sentinel(repo, store, max_seq)
      :ok
    end

    @impl Dust.Cache
    def delete(repo, store, path) do
      query =
        from(c in CacheEntry,
          where: c.store == ^store and c.path == ^path
        )

      repo.delete_all(query)
      :ok
    end

    @impl Dust.Cache
    def last_seq(repo, store) do
      query =
        from(c in CacheEntry,
          where: c.store == ^store and c.path == ^@seq_sentinel_path,
          select: c.seq
        )

      repo.one(query) || 0
    end

    @impl Dust.Cache
    def count(repo, store) do
      query =
        from(c in CacheEntry,
          where: c.store == ^store and c.path != ^@seq_sentinel_path,
          select: count()
        )

      repo.one(query)
    end

    # Chunk size used to walk raw rows when the glob is narrower than the
    # LIKE prefix. Not configurable for Phase 1.
    @browse_chunk_size 500

    @impl Dust.Cache
    def browse(repo, store, opts) do
      pattern = Keyword.get(opts, :pattern, "**")
      cursor = Keyword.get(opts, :cursor)
      limit = Keyword.get(opts, :limit, 50)
      order = Keyword.get(opts, :order, :asc)
      select = Keyword.get(opts, :select, :entries)
      from_key = Keyword.get(opts, :from)
      to_key = Keyword.get(opts, :to)

      matches =
        if is_binary(from_key) and is_binary(to_key) do
          # Range path: SQL bounds are exact, so a single query with limit+1
          # is sufficient — no glob post-filter and no chunked walk.
          range_query(repo, store, from_key, to_key, cursor, order, limit)
        else
          compiled = Dust.Protocol.Glob.compile(pattern)
          literal_like_prefix = literal_like_prefix_of(pattern)

          # Keep fetching chunks of raw rows until we have at least limit+1
          # matches (to detect next page) or the raw source is exhausted.
          collect_matches(
            repo,
            store,
            pattern,
            compiled,
            literal_like_prefix,
            cursor,
            order,
            limit,
            []
          )
        end

      # Decode JSON values — skip decoding entirely when :keys (value is never returned)
      decoded =
        case select do
          :keys ->
            Enum.map(matches, fn {path, _json, _type, _seq} -> {path, nil, nil, nil} end)

          _ ->
            Enum.map(matches, fn {path, json, type, seq} ->
              {path, Jason.decode!(json), type, seq}
            end)
        end

      # Determine pagination
      page = Enum.take(decoded, limit)

      next_cursor =
        if length(decoded) > limit do
          {last_path, _, _, _} = List.last(page)
          last_path
        else
          nil
        end

      projected = project_page(page, select, pattern)

      {projected, next_cursor}
    end

    defp collect_matches(
           repo,
           store,
           pattern,
           compiled,
           literal_like_prefix,
           cursor,
           order,
           limit,
           acc
         ) do
      rows = fetch_chunk(repo, store, literal_like_prefix, cursor, order, @browse_chunk_size)

      filtered =
        if pattern == "**" do
          rows
        else
          Enum.filter(rows, fn {path, _, _, _} ->
            Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
          end)
        end

      all = acc ++ filtered

      cond do
        length(all) > limit ->
          Enum.take(all, limit + 1)

        length(rows) < @browse_chunk_size ->
          all

        true ->
          {last_raw_path, _, _, _} = List.last(rows)

          collect_matches(
            repo,
            store,
            pattern,
            compiled,
            literal_like_prefix,
            last_raw_path,
            order,
            limit,
            all
          )
      end
    end

    # Range query: a single SELECT bounded by [from, to) with limit+1 for
    # cursor detection. No LIKE clause, no glob post-filter, no chunked walk —
    # SQL bounds are exact, so every raw row is a valid match.
    defp range_query(repo, store, from_key, to_key, cursor, order, limit) do
      query =
        from(c in CacheEntry,
          where:
            c.store == ^store and c.path != ^@seq_sentinel_path and
              c.path >= ^from_key and c.path < ^to_key,
          order_by: [{^order, c.path}],
          limit: ^(limit + 1),
          select: {c.path, c.value, c.type, c.seq}
        )

      query =
        if cursor do
          case order do
            :asc -> from(c in query, where: c.path > ^cursor)
            :desc -> from(c in query, where: c.path < ^cursor)
          end
        else
          query
        end

      repo.all(query)
    end

    defp fetch_chunk(repo, store, literal_like_prefix, cursor, order, chunk_size) do
      query =
        from(c in CacheEntry,
          where: c.store == ^store and c.path != ^@seq_sentinel_path,
          order_by: [{^order, c.path}],
          limit: ^chunk_size,
          select: {c.path, c.value, c.type, c.seq}
        )

      query =
        if cursor do
          case order do
            :asc -> from(c in query, where: c.path > ^cursor)
            :desc -> from(c in query, where: c.path < ^cursor)
          end
        else
          query
        end

      query =
        case literal_like_prefix do
          "" ->
            query

          prefix ->
            like_pattern = prefix <> "%"
            from(c in query, where: fragment("? LIKE ? ESCAPE '\\'", c.path, ^like_pattern))
        end

      repo.all(query)
    end

    # Return the literal prefix of a glob pattern — everything before the first
    # segment containing `*` or `**` — with SQL LIKE metacharacters escaped
    # and a trailing dot appended (if non-empty). Returns "" when the pattern
    # starts with a wildcard.
    defp literal_like_prefix_of(pattern) do
      segments = String.split(pattern, ".")

      literal =
        Enum.take_while(segments, fn seg ->
          seg != "*" and seg != "**" and not String.contains?(seg, "*")
        end)

      case literal do
        [] -> ""
        segs -> (Enum.join(segs, ".") <> ".") |> escape_like()
      end
    end

    defp escape_like(literal) do
      literal
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")
    end

    # --- projection helpers (copied verbatim from Dust.Cache.Memory — deliberate
    # duplication per Phase 1 plan; keeps adapters self-contained) ---

    defp project_page(page, :entries, _pattern), do: page
    defp project_page(page, :keys, _pattern), do: Enum.map(page, fn {p, _, _, _} -> p end)
    defp project_page(page, :prefixes, pattern), do: prefixes_of(page, pattern)

    defp prefixes_of(page, pattern) do
      literal_prefix = literal_prefix_of(pattern)

      page
      |> Enum.map(fn {p, _, _, _} -> extract_prefix(p, literal_prefix) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
    end

    defp literal_prefix_of("**"), do: ""

    defp literal_prefix_of(pattern) do
      case String.split(pattern, ".**", parts: 2) do
        [prefix, ""] ->
          prefix

        _ ->
          raise ArgumentError,
                "select: :prefixes requires pattern ending in .** or ** (got #{inspect(pattern)})"
      end
    end

    defp extract_prefix(path, "") do
      case String.split(path, ".", parts: 2) do
        [seg | _] -> seg
        [] -> nil
      end
    end

    defp extract_prefix(path, literal) do
      prefix_with_dot = literal <> "."

      if String.starts_with?(path, prefix_with_dot) do
        rest = String.replace_prefix(path, prefix_with_dot, "")
        [next_seg | _] = String.split(rest, ".", parts: 2)
        literal <> "." <> next_seg
      end
    end

    defp update_seq_sentinel(repo, store, seq) do
      import Ecto.Query

      sentinel = %{
        store: store,
        path: @seq_sentinel_path,
        value: Jason.encode!(seq),
        type: "integer",
        seq: seq
      }

      # Try insert; on conflict only update if new seq is higher
      repo.insert_all(CacheEntry, [sentinel],
        on_conflict:
          from(c in CacheEntry,
            update: [set: [seq: ^seq, value: ^Jason.encode!(seq)]],
            where: c.seq < ^seq
          ),
        conflict_target: [:store, :path]
      )
    end
  end
end
