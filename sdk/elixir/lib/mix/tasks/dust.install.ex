defmodule Mix.Tasks.Dust.Install do
  @shortdoc "Install Dust into your Phoenix app"
  @moduledoc """
  Sets up Dust in your Phoenix application.

      $ mix dust.install

  This task will:

    1. Generate a `MyApp.Dust` module that wraps `use Dust`
    2. Generate the cache migration via `dust.gen.migration`
    3. Print instructions for remaining manual setup steps
  """
  use Mix.Task

  def run(_args) do
    app = Mix.Project.config()[:app]
    app_module = app |> to_string() |> Macro.camelize()
    dust_module = "#{app_module}.Dust"

    # 1. Create the Dust module
    dust_module_path = "lib/#{app}/dust.ex"
    create_file(dust_module_path, dust_module_template(app, dust_module))

    # 2. Generate migration
    Mix.Task.run("dust.gen.migration")

    # 3. Print setup instructions
    Mix.shell().info("""

    Done! Dust has been installed.

    Complete the setup:

    1. Add #{dust_module} to your supervision tree in lib/#{app}/application.ex:

        children = [
          #{app_module}.Repo,
          #{dust_module},
          #{app_module}Web.Endpoint
        ]

    2. Add config to config/config.exs:

        config :#{app}, #{dust_module},
          stores: ["your-org/your-store"],
          repo: #{app_module}.Repo

    3. Add test config to config/test.exs:

        config :#{app}, #{dust_module}, testing: :manual

    4. Set your API key:

        export DUST_API_KEY=dust_tok_...

    5. Run migrations:

        mix ecto.migrate

    """)
  end

  defp dust_module_template(app, module_name) do
    """
    defmodule #{module_name} do
      use Dust, otp_app: :#{app}
    end
    """
  end

  defp create_file(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    if File.exists?(path) do
      Mix.shell().info("* skip #{path} (already exists)")
    else
      File.write!(path, content)
      Mix.shell().info("* creating #{path}")
    end
  end
end
