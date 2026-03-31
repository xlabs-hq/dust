defmodule Dust.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:dust_protocol, path: "../../protocol/elixir"},
      {:slipstream, "~> 1.2"},
      {:msgpax, "~> 2.4"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},
      {:req, "~> 0.5"},
      {:phoenix_pubsub, "~> 2.0", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:ecto_sqlite3, "~> 0.17", only: :test}
    ]
  end
end
