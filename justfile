# Project commands. Run `just --list` to see them all.

# Cut a release of the dustlayer core SDK (sdk/elixir): bump version + CHANGELOG,
# tag dustlayer-v<version>, push — which starts the Hex publish workflow.
release-core:
    elixir scripts/release-sdk.exs sdk/elixir

# Cut a release of dustlayer_ecto (sdk/elixir_ecto). Publish the core FIRST and
# let it land on Hex — this package depends on `{:dustlayer, "~> 0.1"}`.
release-ecto:
    elixir scripts/release-sdk.exs sdk/elixir_ecto

# Run an SDK package's test suite. DIR is sdk/elixir or sdk/elixir_ecto.
test dir:
    cd {{dir}} && mix test

# Format an SDK package. DIR is sdk/elixir or sdk/elixir_ecto.
fmt dir:
    cd {{dir}} && mix format
