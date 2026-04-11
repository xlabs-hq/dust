defmodule Dust.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jamestippett/dust"

  def project do
    [
      app: :dust,
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
      {:decimal, "~> 2.0"},
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
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Dust",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
