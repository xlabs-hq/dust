defmodule DustEcto.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/xlabs-hq/dust/tree/master/sdk/elixir_ecto"

  def project do
    [
      app: :dustlayer_ecto,
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
        extras: ["README.md", "CHANGELOG.md"],
        source_url: @source_url,
        source_ref: "dustlayer_ecto-v#{@version}"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {DustEcto.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:dustlayer, dustlayer_dep()},
      {:ecto, "~> 3.12"},
      {:req, "~> 0.5"},
      # Plug is only used in tests (Req.Test stubs hitting our HTTP
      # transport without a real server). It's also a transitive dep of
      # :dustlayer via Phoenix-shaped tooling, so production users won't see
      # an extra dep here.
      {:plug, "~> 1.0", only: [:dev, :test]},
      # phoenix_pubsub is an optional integration: dust_ecto's
      # DustEcto.Phoenix module compiles without it and only activates
      # at runtime if the user has it loaded. The test-only dep here
      # exists so our own tests can exercise the bridge.
      {:phoenix_pubsub, "~> 2.0", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # In the monorepo (dev, test, CI) depend on the sibling `dustlayer` source so
  # core changes are picked up without a publish round-trip. `mix hex.publish`
  # rejects path deps, so the release workflow sets DUST_HEX=1 to pin the
  # published version into the package's dependency metadata instead.
  defp dustlayer_dep do
    if System.get_env("DUST_HEX"), do: "~> 0.1", else: [path: "../elixir"]
  end

  defp description do
    "Ecto-shaped facade over Dust — Dust.Schema + Dust.Repo for Phoenix apps."
  end

  defp package do
    [
      maintainers: ["James Tippett"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" =>
          "https://github.com/xlabs-hq/dust/blob/master/sdk/elixir_ecto/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
