defmodule Mix.Tasks.Dust.Gen.Migration do
  @shortdoc "Generates a migration for the Dust cache table"
  @moduledoc """
  Generates a migration that creates the `dust_cache` table.

      $ mix dust.gen.migration

  The migration will be added to your application's repo migration directory.

  ## Options

    * `-r`, `--repo` - the repo to generate the migration for.
      Defaults to the app's primary repo.
  """
  use Mix.Task

  import Mix.Ecto
  import Mix.Generator

  def run(args) do
    no_umbrella!("dust.gen.migration")
    repos = parse_repo(args)

    Enum.each(repos, fn repo ->
      ensure_repo(repo, args)
      path = Ecto.Migrator.migrations_path(repo)

      source_path =
        :dust
        |> Application.app_dir("priv/templates/dust.gen.migration/migration.exs.eex")

      generated_file = EEx.eval_file(source_path, module_prefix: app_module())

      target_file = Path.join(path, "#{timestamp()}_create_dust_cache.exs")
      create_directory(path)
      create_file(target_file, generated_file)
    end)
  end

  defp app_module do
    Mix.Project.config()[:app]
    |> to_string()
    |> Macro.camelize()
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)
end
