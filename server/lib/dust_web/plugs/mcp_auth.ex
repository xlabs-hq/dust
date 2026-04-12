defmodule DustWeb.Plugs.MCPAuth do
  @moduledoc """
  Authenticates MCP requests via Bearer token.

  Accepts two token kinds:

    1. Legacy single-store tokens (`dust_tok_…`) authenticated via
       `Dust.Stores.authenticate_token/1`.
    2. OAuth-issued opaque session tokens authenticated via
       `Dust.MCP.Sessions.find_by_access_token_hash/1`. These slide their
       expiry on each successful request.

  On success, sets `:mcp_principal` (and a legacy `:store_token` assign for
  back-compat). On failure, returns 401 with a `WWW-Authenticate` challenge
  pointing at the protected resource metadata endpoint.
  """

  import Plug.Conn

  alias Dust.MCP.Principal
  alias Dust.MCP.Sessions
  alias Dust.Stores

  def init(opts), do: opts

  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, %Principal{} = principal} ->
        conn
        |> assign(:mcp_principal, principal)
        |> assign_legacy(principal)

      {:error, message} ->
        send_unauthorized(conn, message)
    end
  end

  defp authenticate(conn) do
    with {:ok, raw} <- extract_bearer(conn),
         {:ok, principal} <- principal_for(raw) do
      {:ok, principal}
    end
  end

  defp principal_for("dust_tok_" <> _ = raw) do
    case Stores.authenticate_token(raw) do
      {:ok, store_token} ->
        {:ok, %Principal{kind: :store_token, store_token: store_token}}

      _ ->
        {:error, "invalid token"}
    end
  end

  defp principal_for(raw) do
    hash = Sessions.hash_token(raw)

    case Sessions.find_by_access_token_hash(hash) do
      nil ->
        {:error, "invalid token"}

      session ->
        if expired?(session) do
          {:error, "token expired"}
        else
          {:ok, slid} = Sessions.touch_and_slide(session)
          {:ok, %Principal{kind: :user_session, user: slid.user, session: slid}}
        end
    end
  end

  defp expired?(session) do
    DateTime.compare(session.expires_at, DateTime.utc_now()) != :gt
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, "missing bearer token"}
    end
  end

  defp assign_legacy(conn, %Principal{kind: :store_token, store_token: token}) do
    assign(conn, :store_token, token)
  end

  defp assign_legacy(conn, _principal), do: conn

  defp send_unauthorized(conn, message) do
    base_url = Application.get_env(:dust, :mcp_base_url, DustWeb.Endpoint.url())

    challenge =
      ~s(Bearer error="unauthorized", error_description="#{message}", resource_metadata="#{base_url}/.well-known/oauth-protected-resource")

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized", error_description: message}))
    |> halt()
  end
end
