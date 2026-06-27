defmodule Dust.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/xlabs-hq/dust"

  def project do
    [
      app: :dustlayer,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      description: "Reactive global state for Elixir apps",
      source_url: @source_url,
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Core
      {:slipstream, "~> 1.2"},
      {:msgpax, "~> 2.4"},
      {:jason, "~> 1.4"},
      # Pinned wide: `decimal 2.0` is what most existing Phoenix apps
      # carry via transitive Ecto/Jason deps. `~> 3.1` would force every
      # adopter to add `override: true` to their lock — friction we don't
      # need. Dust only uses `Decimal` for serialization round-trips.
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:req, "~> 0.5"},

      # Optional integrations
      {:phoenix_pubsub, "~> 2.0", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},

      # Dev/Test
      {:ecto_sqlite3, "~> 0.17", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["James Tippett"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/sdk/elixir/CHANGELOG.md"
      },
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Dust",
      source_ref: "dustlayer-v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
