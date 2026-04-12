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

  def oauth_authorize(
        conn,
        %{
          "response_type" => _,
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "state" => state,
          "code_challenge" => challenge,
          "code_challenge_method" => method
        } = params
      ) do
    oauth_state =
      if String.starts_with?(state, "oauth_flow_") do
        state
      else
        "oauth_flow_" <> state
      end

    conn =
      put_session(conn, :oauth_params, %{
        client_id: client_id,
        redirect_uri: redirect_uri,
        state: oauth_state,
        code_challenge: challenge,
        code_challenge_method: method,
        scope: Map.get(params, "scope", "")
      })

    # Mint our own PKCE for the upstream WorkOS exchange
    upstream_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    upstream_challenge =
      :crypto.hash(:sha256, upstream_verifier) |> Base.url_encode64(padding: false)

    conn = put_session(conn, :code_verifier, upstream_verifier)

    query =
      URI.encode_query(%{
        client_id: Application.fetch_env!(:workos, :mcp_client_id),
        response_type: "code",
        redirect_uri: "#{base_url()}/oauth/callback",
        scope: "profile email",
        state: oauth_state,
        code_challenge: upstream_challenge,
        code_challenge_method: "S256"
      })

    authkit = Application.fetch_env!(:dust, :authkit_base_url)
    redirect(conn, external: "#{authkit}/oauth2/authorize?#{query}")
  end

  def oauth_authorize(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "invalid_request",
      error_description: "Missing required OAuth parameters"
    })
  end

  defp base_url do
    Application.fetch_env!(:dust, :mcp_base_url)
  end
end
