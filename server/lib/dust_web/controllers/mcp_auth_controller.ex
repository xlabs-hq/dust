defmodule DustWeb.MCPAuthController do
  use DustWeb, :controller

  require Logger

  alias Dust.Accounts
  alias Dust.MCP.Sessions
  alias Dust.WorkOSClient

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
    # Always prefix unconditionally. Idempotency ("only prefix if not already
    # prefixed") is wrong because a client may legitimately send a state that
    # starts with "oauth_flow_", and the callback strip would then return the
    # wrong value to the client.
    oauth_state = "oauth_flow_" <> state

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

  def oauth_callback(conn, %{"code" => code} = params) do
    oauth_params = get_session(conn, :oauth_params) || %{}
    code_verifier = get_session(conn, :code_verifier)
    client_redirect = oauth_params[:redirect_uri]
    stored_state = oauth_params[:state] || ""
    callback_state = Map.get(params, "state", "")

    cond do
      is_nil(code_verifier) ->
        json_error(conn, :bad_request, "missing_session", "Missing PKCE verifier")

      is_nil(client_redirect) ->
        json_error(conn, :bad_request, "missing_redirect_uri", "Missing client redirect_uri")

      stored_state != callback_state ->
        json_error(conn, :bad_request, "state_mismatch", "State does not match")

      true ->
        do_callback(conn, code, code_verifier, oauth_params, client_redirect, stored_state)
    end
  end

  defp do_callback(conn, code, code_verifier, oauth_params, client_redirect, stored_state) do
    with {:ok, %{user: workos_user}} <-
           WorkOSClient.exchange_and_get_user(%{
             code: code,
             code_verifier: code_verifier,
             client_id: Application.fetch_env!(:workos, :mcp_client_id),
             redirect_uri: "#{base_url()}/oauth/callback"
           }),
         {:ok, user} <- Accounts.find_or_create_user_from_workos(workos_user),
         {:ok, session} <-
           Sessions.create_authorization_code(user, %{
             client_id: oauth_params[:client_id],
             client_redirect_uri: oauth_params[:redirect_uri],
             code_challenge: oauth_params[:code_challenge],
             code_challenge_method: oauth_params[:code_challenge_method],
             remote_ip: peer_ip(conn),
             user_agent: user_agent(conn)
           }) do
      original_state = String.replace_prefix(stored_state, "oauth_flow_", "")
      callback_url = build_callback_url(client_redirect, session.session_id, original_state)
      redirect(conn, external: callback_url)
    else
      {:error, reason} ->
        Logger.error("MCP oauth_callback failed: #{inspect(reason)}")
        json_error(conn, :unauthorized, "authentication_failed", "Could not authenticate")
    end
  end

  def oauth_token(conn, %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri
      }) do
    case Sessions.exchange_code(code, %{
           code_verifier: verifier,
           client_id: client_id,
           client_redirect_uri: redirect_uri
         }) do
      {:ok, raw, session} ->
        expires_in = DateTime.diff(session.expires_at, DateTime.utc_now(), :second) |> max(0)

        json(conn, %{
          access_token: raw,
          token_type: "Bearer",
          expires_in: expires_in,
          scope: "profile email"
        })

      {:error, reason}
      when reason in [:invalid_grant, :already_used, :pkce_mismatch, :client_mismatch] ->
        json_error(conn, :bad_request, "invalid_grant", to_string(reason))

      {:error, _} ->
        json_error(
          conn,
          :bad_request,
          "invalid_grant",
          "Authorization grant could not be exchanged"
        )
    end
  end

  def oauth_token(conn, %{"grant_type" => "authorization_code"}) do
    json_error(conn, :bad_request, "invalid_request", "Missing required token parameters")
  end

  def oauth_token(conn, _params) do
    json_error(
      conn,
      :bad_request,
      "unsupported_grant_type",
      "Only authorization_code is supported"
    )
  end

  defp build_callback_url(redirect_uri, code, state) do
    uri = URI.parse(redirect_uri)
    existing = if uri.query, do: URI.decode_query(uri.query), else: %{}
    query = existing |> Map.put("code", code) |> Map.put("state", state) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  defp peer_ip(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end

  defp user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end

  defp json_error(conn, status, error, description) do
    conn
    |> put_status(status)
    |> json(%{error: error, error_description: description})
  end

  defp base_url do
    Application.fetch_env!(:dust, :mcp_base_url)
  end
end
