defmodule DustWeb.MCPAuth.FlowToken do
  @moduledoc """
  Signs and verifies the opaque token that carries OAuth flow params
  through the embedded login bounce. The flow params live in the URL
  query string (`?flow=...`), so they survive `clear_session` in
  `log_in_user/2` without polluting the session cookie.
  """

  alias DustWeb.Endpoint

  @salt "mcp_oauth_flow_v1"
  # 10 minutes is enough for a login + SSO bounce.
  @max_age 600

  @spec encode(map()) :: binary()
  def encode(oauth_params) when is_map(oauth_params) do
    Phoenix.Token.sign(Endpoint, @salt, oauth_params)
  end

  @spec verify(binary()) :: {:ok, map()} | {:error, term()}
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)
  end
end
