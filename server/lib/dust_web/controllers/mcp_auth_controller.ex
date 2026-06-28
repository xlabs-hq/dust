defmodule DustWeb.MCPAuthController do
  use DustWeb, :controller

  require Logger

  alias Dust.MCP.Sessions
  alias DustWeb.MCPAuth.FlowToken
  alias DustWeb.OAuth.RedirectUriValidator

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
    # Dynamic Client Registration: mint a fresh client_id per registration.
    # The MCP client uses this identifier in subsequent /oauth/authorize and
    # /oauth/token calls. We do not yet persist DCR clients server-side; the
    # client_id is opaque to us and only used for display/logging.
    client_id = "client_" <> Ecto.UUID.generate()

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
    cond do
      not RedirectUriValidator.valid?(redirect_uri) ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_request",
          error_description: "redirect_uri is not on the allowlist"
        })

      method != "S256" ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_request",
          error_description: "only S256 is supported for code_challenge_method"
        })

      true ->
        do_authorize(conn, client_id, redirect_uri, state, challenge, method, params)
    end
  end

  def oauth_authorize(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "invalid_request",
      error_description: "Missing required OAuth parameters"
    })
  end

  defp do_authorize(conn, client_id, redirect_uri, state, challenge, method, params) do
    oauth_params = %{
      client_id: client_id,
      redirect_uri: redirect_uri,
      state: state,
      code_challenge: challenge,
      code_challenge_method: method,
      scope: Map.get(params, "scope", "")
    }

    flow_token = FlowToken.encode(oauth_params)
    continue_path = "/oauth/authorize/continue?" <> URI.encode_query(%{flow: flow_token})

    if signed_in?(conn) do
      redirect(conn, to: continue_path)
    else
      conn
      |> put_session(:user_return_to, continue_path)
      |> redirect(to: "/auth/login")
    end
  end

  defp signed_in?(conn) do
    case conn.assigns[:current_scope] do
      %{user: %_{}} -> true
      _ -> false
    end
  end

  def authorize_continue(conn, %{"flow" => flow_token}) do
    cond do
      not signed_in?(conn) ->
        conn
        |> put_session(:user_return_to, current_path(conn))
        |> redirect(to: "/auth/login")

      true ->
        case FlowToken.verify(flow_token) do
          {:ok, oauth_params} ->
            user = conn.assigns.current_scope.user

            render_inertia(conn, "OAuth/Authorize", %{
              client_id: oauth_params.client_id,
              client_name: client_display_name(oauth_params.client_id),
              redirect_uri: oauth_params.redirect_uri,
              user_email: user.email,
              flow: flow_token
            })

          {:error, _} ->
            json_error(conn, :bad_request, "invalid_request", "Flow token is invalid or expired")
        end
    end
  end

  def authorize_continue(conn, _params) do
    json_error(conn, :bad_request, "invalid_request", "Missing flow token")
  end

  # DCR clients don't yet store a display name in the DB; fall back to client_id.
  # When DCR persistence lands, look up the registered client name here.
  defp client_display_name(client_id), do: client_id

  def authorize_approve(conn, %{"flow" => flow_token, "action" => action})
      when action in ["allow", "deny"] do
    cond do
      not signed_in?(conn) ->
        redirect(conn, to: "/auth/login")

      true ->
        case FlowToken.verify(flow_token) do
          {:ok, oauth_params} ->
            do_approve(conn, oauth_params, action)

          {:error, _} ->
            json_error(conn, :bad_request, "invalid_request", "Flow token is invalid or expired")
        end
    end
  end

  def authorize_approve(conn, _params) do
    json_error(conn, :bad_request, "invalid_request", "Missing flow or action")
  end

  defp do_approve(conn, oauth_params, action) when action in ["allow", "deny"] do
    # Re-validate the redirect_uri against the current allowlist before
    # honoring it. The flow token preserved the redirect_uri from the
    # initial /oauth/authorize hop, but allowlist config could have
    # changed (or the URI could have been signed under an older policy).
    # We must never redirect to an unvalidated external URL.
    if RedirectUriValidator.valid?(oauth_params.redirect_uri) do
      do_approve_validated(conn, oauth_params, action)
    else
      json_error(conn, :bad_request, "invalid_request", "redirect_uri is no longer trusted")
    end
  end

  defp do_approve_validated(conn, oauth_params, "deny") do
    url = error_redirect(oauth_params.redirect_uri, "access_denied", oauth_params.state)
    redirect(conn, external: url)
  end

  defp do_approve_validated(conn, oauth_params, "allow") do
    user = conn.assigns.current_scope.user

    case Sessions.create_authorization_code(user, %{
           client_id: oauth_params.client_id,
           client_redirect_uri: oauth_params.redirect_uri,
           code_challenge: oauth_params.code_challenge,
           code_challenge_method: oauth_params.code_challenge_method,
           remote_ip: peer_ip(conn),
           user_agent: user_agent(conn)
         }) do
      {:ok, session} ->
        url =
          build_callback_url(oauth_params.redirect_uri, session.session_id, oauth_params.state)

        redirect(conn, external: url)

      {:error, reason} ->
        Logger.error("create_authorization_code failed: #{inspect(reason)}")
        url = error_redirect(oauth_params.redirect_uri, "server_error", oauth_params.state)
        redirect(conn, external: url)
    end
  end

  defp error_redirect(redirect_uri, error, state) do
    uri = URI.parse(redirect_uri)
    existing = if uri.query, do: URI.decode_query(uri.query), else: %{}
    query = existing |> Map.put("error", error) |> Map.put("state", state) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
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
