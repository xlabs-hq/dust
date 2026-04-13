defmodule Dust.WorkOSClient do
  @moduledoc """
  Indirection for WorkOS AuthKit OAuth calls so tests can stub them. The
  default implementation (`Dust.WorkOSClient.Default`) hits AuthKit's standard
  OAuth 2.0 endpoints (`/oauth2/token` and `/oauth2/userinfo`) directly via Req
  so we can send PKCE verifiers and route through the dedicated MCP client_id.

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
