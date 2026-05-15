defmodule Dust.MigratePaths do
  @moduledoc """
  Rewrite legacy dotted paths to canonical slash-rendered paths in every
  per-store SQLite file under the configured `store_data_dir`.

  Callable from IEx (including `bin/dust remote` on a running release) so
  that operators can migrate production stores without a Mix runtime:

      iex> Dust.MigratePaths.run([])                # dry run, report only
      iex> Dust.MigratePaths.run(apply: true)       # rewrite paths in place
      iex> Dust.MigratePaths.run(apply: true, store_data_dir: "/app/data/stores")

  Each DB carries a `PRAGMA user_version` marker; once migrated to capver 3
  it is skipped on subsequent runs.
  """

  alias DustProtocol.Path, as: DPath
  alias DustProtocol.Path.LegacyDot

  @path_schema_version 3

  @type counts :: %{op_rewrites: non_neg_integer(), entry_rewrites: non_neg_integer()}
  @type summary :: %{
          skipped: [String.t()],
          migrated: [{String.t(), counts}],
          errored: [{String.t(), term()}]
        }

  @doc """
  Run the migration.

  Options:

    * `:apply` — when `true`, write the rewrite. Defaults to `false` (dry run).
    * `:store_data_dir` — directory to scan for `*.db` files. Defaults to
      `Application.get_env(:dust, :store_data_dir, "priv/stores")`.

  Returns `{:ok, summary}` after printing a summary to stdout. Returns
  `{:error, {:bad_store_data_dir, dir}}` if the directory does not exist
  or cannot be read.
  """
  @spec run(keyword) ::
          {:ok, summary} | {:error, {:bad_store_data_dir, String.t()}}
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    dir = Keyword.get(opts, :store_data_dir) || default_store_data_dir()

    IO.puts("scanning #{dir} (#{if apply?, do: "apply", else: "dry-run"})")

    case find_dbs(dir) do
      {:error, reason} ->
        {:error, {:bad_store_data_dir, "#{dir} (#{inspect(reason)})"}}

      {:ok, []} ->
        IO.puts("no .db files found")
        {:ok, %{skipped: [], migrated: [], errored: []}}

      {:ok, dbs} ->
        results = Enum.map(dbs, &migrate_file(&1, apply?))
        summary = summarize_results(results)
        print_summary(summary, apply?)
        {:ok, summary}
    end
  end

  defp default_store_data_dir do
    Application.get_env(:dust, :store_data_dir, "priv/stores")
  end

  defp find_dbs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        {:ok, entries |> Enum.flat_map(&expand_entry(Path.join(dir, &1))) |> Enum.sort()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_entry(path) do
    cond do
      File.dir?(path) ->
        case find_dbs(path) do
          {:ok, paths} -> paths
          {:error, _} -> []
        end

      String.ends_with?(path, ".db") ->
        [path]

      true ->
        []
    end
  end

  # Returns {db_path, :skipped | {:ok, counts} | {:error, reason}}.
  defp migrate_file(db_path, apply?) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path)

    result =
      case current_version(db) do
        v when v >= @path_schema_version ->
          {db_path, :skipped}

        _ ->
          case build_plan(db) do
            {:ok, plan} when apply? ->
              :ok = apply_plan(db, plan)
              {db_path, {:ok, summarize(plan)}}

            {:ok, plan} ->
              {db_path, {:ok, summarize(plan)}}

            {:error, _} = err ->
              {db_path, err}
          end
      end

    Exqlite.Sqlite3.close(db)
    result
  end

  defp current_version(db) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "PRAGMA user_version")

    val =
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, [n]} when is_integer(n) -> n
        _ -> 0
      end

    :ok = Exqlite.Sqlite3.release(db, stmt)
    val
  end

  defp build_plan(db) do
    with {:ok, ops} <- distinct_paths(db, "store_ops"),
         {:ok, entries} <- distinct_paths(db, "store_entries"),
         {:ok, op_map} <- map_paths(ops),
         {:ok, entry_map} <- map_paths(entries),
         :ok <- check_entry_collisions(entries, entry_map) do
      {:ok, %{ops: op_map, entries: entry_map}}
    end
  end

  defp distinct_paths(db, table) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT DISTINCT path FROM #{table}")
    rows = collect_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    {:ok, Enum.map(rows, fn [p] -> p end)}
  end

  defp collect_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> collect_rows(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp map_paths(paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn old, {:ok, acc} ->
      case rewrite(old) do
        {:ok, ^old} -> {:cont, {:ok, acc}}
        {:ok, new} -> {:cont, {:ok, Map.put(acc, old, new)}}
        {:error, reason} -> {:halt, {:error, {old, reason}}}
      end
    end)
  end

  defp rewrite(old) do
    with {:ok, segs} <- LegacyDot.parse(old),
         {:ok, new} <- DPath.render(segs) do
      {:ok, new}
    end
  end

  defp check_entry_collisions(entry_paths, entry_map) do
    new_to_olds =
      entry_paths
      |> Enum.map(fn old ->
        case Map.fetch(entry_map, old) do
          {:ok, new} -> {new, old}
          :error -> {old, old}
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    case Enum.filter(new_to_olds, fn {_new, olds} -> length(olds) > 1 end) do
      [] -> :ok
      conflicts -> {:error, {:entry_collision, conflicts}}
    end
  end

  defp summarize(%{ops: ops, entries: entries}) do
    %{op_rewrites: map_size(ops), entry_rewrites: map_size(entries)}
  end

  defp apply_plan(db, %{ops: ops, entries: entries}) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN IMMEDIATE")

    Enum.each(ops, &update_path(db, "store_ops", &1))
    Enum.each(entries, &update_path(db, "store_entries", &1))

    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA user_version = #{@path_schema_version}")
    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    :ok
  end

  defp update_path(db, table, {old, new}) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "UPDATE #{table} SET path = ?1 WHERE path = ?2")
    :ok = Exqlite.Sqlite3.bind(stmt, [new, old])
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
  end

  defp summarize_results(results) do
    Enum.reduce(results, %{skipped: [], migrated: [], errored: []}, fn
      {p, :skipped}, acc -> %{acc | skipped: [p | acc.skipped]}
      {p, {:ok, counts}}, acc -> %{acc | migrated: [{p, counts} | acc.migrated]}
      {p, {:error, reason}}, acc -> %{acc | errored: [{p, reason} | acc.errored]}
    end)
    |> Map.update!(:skipped, &Enum.reverse/1)
    |> Map.update!(:migrated, &Enum.reverse/1)
    |> Map.update!(:errored, &Enum.reverse/1)
  end

  defp print_summary(summary, apply?) do
    IO.puts("\n--- migration summary ---")
    IO.puts("already at capver #{@path_schema_version}: #{length(summary.skipped)}")

    IO.puts("#{if apply?, do: "rewritten", else: "would rewrite"}: #{length(summary.migrated)}")

    Enum.each(summary.migrated, fn {p, c} ->
      IO.puts("  #{p}  ops=#{c.op_rewrites} entries=#{c.entry_rewrites}")
    end)

    if summary.errored != [] do
      IO.puts(:stderr, "errors: #{length(summary.errored)}")

      Enum.each(summary.errored, fn {p, reason} ->
        IO.puts(:stderr, "  #{p}: #{inspect(reason)}")
      end)
    end
  end
end
