defmodule Mix.Tasks.Dust.MigratePaths do
  @moduledoc """
  Rewrite legacy dotted paths to canonical slash-rendered paths in every
  per-store SQLite file under the configured `store_data_dir`.

  Defaults to a dry run. Pass `--apply` to actually write changes.

      mix dust.migrate_paths                # dry run, report only
      mix dust.migrate_paths --apply        # rewrite paths in place
      mix dust.migrate_paths --store-data-dir /tmp/stores --apply

  Each DB carries a `PRAGMA user_version` marker; once migrated to capver 3
  it is skipped on subsequent runs.
  """

  use Mix.Task

  alias DustProtocol.Path, as: DPath
  alias DustProtocol.Path.LegacyDot

  @path_schema_version 3

  @shortdoc "Migrate per-store SQLite path columns to capver 3 (slash-rendered)."

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [apply: :boolean, store_data_dir: :string],
        aliases: [a: :apply, d: :store_data_dir]
      )

    apply? = Keyword.get(opts, :apply, false)
    dir = Keyword.get(opts, :store_data_dir) || default_store_data_dir()

    Mix.shell().info("scanning #{dir} (#{if apply?, do: "apply", else: "dry-run"})")

    case find_dbs(dir) do
      [] ->
        Mix.shell().info("no .db files found")

      dbs ->
        results = Enum.map(dbs, &migrate_file(&1, apply?))
        report(results, apply?)
    end
  end

  defp default_store_data_dir do
    # Read from config without booting the full app.
    Mix.Task.run("app.config")
    Application.get_env(:dust, :store_data_dir, "priv/stores")
  end

  defp find_dbs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(&expand_entry(Path.join(dir, &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp expand_entry(path) do
    cond do
      File.dir?(path) -> find_dbs(path)
      String.ends_with?(path, ".db") -> [path]
      true -> []
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

  # Returns {:ok, %{old => new}} skipping unchanged entries.
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
    # If two different entry paths rewrite to the same new path, abort —
    # we can't decide which row to keep.
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

  defp report(results, apply?) do
    {skipped, migrated, errored} =
      Enum.reduce(results, {[], [], []}, fn
        {p, :skipped}, {s, m, e} -> {[p | s], m, e}
        {p, {:ok, counts}}, {s, m, e} -> {s, [{p, counts} | m], e}
        {p, {:error, reason}}, {s, m, e} -> {s, m, [{p, reason} | e]}
      end)

    Mix.shell().info("\n--- migration summary ---")
    Mix.shell().info("already at capver #{@path_schema_version}: #{length(skipped)}")
    Mix.shell().info("#{if apply?, do: "rewritten", else: "would rewrite"}: #{length(migrated)}")

    Enum.each(migrated, fn {p, c} ->
      Mix.shell().info("  #{p}  ops=#{c.op_rewrites} entries=#{c.entry_rewrites}")
    end)

    if errored != [] do
      Mix.shell().error("errors: #{length(errored)}")

      Enum.each(errored, fn {p, reason} ->
        Mix.shell().error("  #{p}: #{inspect(reason)}")
      end)

      Mix.raise("migration finished with errors")
    end
  end
end
