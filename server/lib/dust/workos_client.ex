defmodule Dust.WorkOSClient do
  @moduledoc """
  Indirection for WorkOS AuthKit OAuth calls so tests can stub them. The
  default implementation hits AuthKit's standard OAuth 2.0 endpoints
  (`/oauth2/token` and `/oauth2/userinfo`) directly via Req so we can send
  PKCE verifiers and route through the dedicated MCP client_id.

  We intentionally do NOT use `WorkOS.UserManagement.authenticate_with_code/1`
  because it:

    1. hardcodes the default WorkOS client_id/secret (ignoring our separate
       MCP client), and
    2. has no way to pass the PKCE `code_verifier`, so the upstream leg of
       the OAuth flow is unprotected.
  """

  @callback exchange_and_get_user(map()) ::
              {:ok, %{user: WorkOS.UserManagement.User.t()}} | {:error, term()}

  def impl, do: Application.get_env(:dust, :workos_client, __MODULE__.Default)

  def exchange_and_get_user(params), do: impl().exchange_and_get_user(params)
end

defmodule Dust.WorkOSClient.Default do
  @behaviour Dust.WorkOSClient

  require Logger

  alias WorkOS.UserManagement.User

  @impl true
  def exchange_and_get_user(%{
        code: code,
        code_verifier: code_verifier,
        client_id: client_id,
        redirect_uri: redirect_uri
      }) do
    authkit = Application.fetch_env!(:dust, :authkit_base_url)

    with {:ok, tokens} <- exchange_token(authkit, code, code_verifier, client_id, redirect_uri),
         {:ok, access_token} <- extract_access_token(tokens),
         {:ok, userinfo} <- get_user_info(authkit, access_token) do
      {:ok, %{user: build_user(userinfo)}}
    end
  end

  defp exchange_token(authkit, code, code_verifier, client_id, redirect_uri) do
    form = [
      grant_type: "authorization_code",
      code: code,
      code_verifier: code_verifier,
      client_id: client_id,
      redirect_uri: redirect_uri
    ]

    Logger.info("Exchanging AuthKit code - url: #{authkit}/oauth2/token, client_id: #{client_id}")

    case Req.post("#{authkit}/oauth2/token",
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           form: form
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "AuthKit token exchange failed - status: #{status}, body: #{inspect(body)}"
        )

        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.error("AuthKit token exchange error - reason: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_access_token(%{"access_token" => token}) when is_binary(token), do: {:ok, token}
  defp extract_access_token(_), do: {:error, :no_access_token}

  defp get_user_info(authkit, access_token) do
    case Req.get("#{authkit}/oauth2/userinfo",
           headers: [{"authorization", "Bearer " <> access_token}]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("AuthKit userinfo failed - status: #{status}, body: #{inspect(body)}")
        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.error("AuthKit userinfo error - reason: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_user(userinfo) do
    # AuthKit's /oauth2/userinfo returns OIDC claims. The WorkOS.UserManagement.User
    # struct has @enforce_keys for email_verified/updated_at/created_at, which the
    # OIDC userinfo payload does not provide. We default them to safe values since
    # this struct is only consumed as an intermediate representation by
    # Accounts.find_or_create_user_from_workos/1 which only reads id/email/first_name/last_name.
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %User{
      id: userinfo["sub"] || userinfo["id"] || "",
      email: userinfo["email"],
      first_name: userinfo["given_name"] || userinfo["first_name"],
      last_name: userinfo["family_name"] || userinfo["last_name"],
      email_verified: Map.get(userinfo, "email_verified", true),
      created_at: now,
      updated_at: now
    }
  end
end
