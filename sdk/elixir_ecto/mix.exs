defmodule DustEcto.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/xlabs-hq/dust/tree/master/sdk/elixir_ecto"

  def project do
    [
      app: :dust_ecto,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      name: "DustEcto",
      source_url: @source_url,
      docs: [
        main: "readme",
        extras: ["README.md"],
        source_url: @source_url,
        source_ref: "v#{@version}"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:dust, path: "../elixir"},
      {:ecto, "~> 3.12"},
      {:req, "~> 0.5"},
      # Plug is only used in tests (Req.Test stubs hitting our HTTP
      # transport without a real server). It's also a transitive dep of
      # :dust via Phoenix-shaped tooling, so production users won't see
      # an extra dep here.
      {:plug, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Ecto-shaped facade over Dust — Dust.Schema + Dust.Repo for Phoenix apps."
  end

  defp package do
    [
      maintainers: ["James Tippett"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md)
    ]
  end
end
