defmodule DustWeb.MCPAuthController do
  use DustWeb, :controller

  require Logger

  def oauth_protected_resource(conn, _params) do
    base = base_url()

    json(conn, %{
      resource: base,
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
      resource_documentation: base
    })
  end

  def oauth_authorization_server(conn, _params) do
    base = base_url()

    json(conn, %{
      issuer: base,
      authorization_endpoint: "#{base}/oauth/authorize",
      token_endpoint: "#{base}/oauth/token",
      registration_endpoint: "#{base}/register",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["profile", "email"]
    })
  end

  def register(conn, params) do
    client_id = Application.fetch_env!(:workos, :mcp_client_id)

    response = %{
      client_id: client_id,
      client_name: params["client_name"],
      redirect_uris: params["redirect_uris"] || [],
      grant_types: params["grant_types"] || ["authorization_code"],
      response_types: params["response_types"] || ["code"],
      token_endpoint_auth_method: params["token_endpoint_auth_method"] || "none",
      authorization_endpoint: "#{base_url()}/oauth/authorize",
      token_endpoint: "#{base_url()}/oauth/token"
    }

    json(conn, response)
  end

  defp base_url do
    Application.fetch_env!(:dust, :mcp_base_url)
  end
end
