defmodule Mix.Tasks.Dust.MigratePaths do
  @moduledoc """
  Rewrite legacy dotted paths to canonical slash-rendered paths in every
  per-store SQLite file under the configured `store_data_dir`.

  Defaults to a dry run. Pass `--apply` to actually write changes.

      mix dust.migrate_paths                # dry run, report only
      mix dust.migrate_paths --apply        # rewrite paths in place
      mix dust.migrate_paths --store-data-dir /tmp/stores --apply

  This task is a thin wrapper around `Dust.MigratePaths.run/1`. Production
  operators without `mix` should call that function directly via
  `bin/dust remote`:

      iex> Dust.MigratePaths.run(apply: true)

  Each DB carries a `PRAGMA user_version` marker; once migrated to capver 3
  it is skipped on subsequent runs.
  """

  use Mix.Task

  @shortdoc "Migrate per-store SQLite path columns to capver 3 (slash-rendered)."

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [apply: :boolean, store_data_dir: :string],
        aliases: [a: :apply, d: :store_data_dir]
      )

    case Dust.MigratePaths.run(opts) do
      {:ok, %{errored: []}} ->
        :ok

      {:ok, %{errored: errors}} ->
        Mix.raise("migration finished with #{length(errors)} errors")

      {:error, {:bad_store_data_dir, dir}} ->
        Mix.raise("could not read store_data_dir: #{dir}")
    end
  end
end
