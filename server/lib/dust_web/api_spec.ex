defmodule DustWeb.ApiSpec do
  @moduledoc """
  Top-level OpenAPI 3.1 spec for the Dust HTTP API. Endpoints with
  `operation` annotations on their controller actions are picked up
  automatically by `Oaskit.Spec.Paths.from_router/2`.

  Browse the spec at `/api-docs` (Redoc UI) or `/openapi.json` (raw).
  """
  use Oaskit

  alias Oaskit.Spec.Paths
  alias Oaskit.Spec.Server

  @impl true
  def spec do
    %{
      openapi: "3.1.1",
      info: %{
        title: "Dust API",
        version: "0.1.0",
        description: """
        HTTP API for [Dust](https://dustlayer.io) — reactive global state for AI agents.

        All endpoints require a Bearer token in the `Authorization` header.
        Tokens are scoped to a store and have read or write permissions.

        Source: <https://github.com/xlabs-hq/dust>.
        """
      },
      servers: [Server.from_config(:dust, DustWeb.Endpoint)],
      paths: Paths.from_router(DustWeb.Router, filter: &String.starts_with?(&1.path, "/api/")),
      components: %{
        securitySchemes: %{
          "bearerAuth" => %{
            type: "http",
            scheme: "bearer",
            description: "Bearer token scoped to a store. Create at `/:org/tokens`."
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    }
  end
end
