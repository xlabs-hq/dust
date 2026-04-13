defmodule DustWeb.OAuth.RedirectUriValidator do
  @moduledoc """
  Validates an MCP client's OAuth redirect_uri against a safe allowlist.

  Loopback interfaces (127.0.0.1, ::1, localhost) are always permitted
  because an attacker cannot reach the victim's loopback. Remote hosts
  must match a configured prefix in `:dust, :mcp_redirect_uri_allowlist`.

  NOTE: this is a minimal defensive allowlist. True per-client redirect
  URI binding requires real Dynamic Client Registration (RFC 7591) with
  Postgres-persisted client records — that is a follow-up. Until then,
  operators opt in to remote redirect hosts via configuration.
  """

  @loopback_hosts ["127.0.0.1", "::1", "localhost"]

  @spec valid?(term()) :: boolean()
  def valid?(redirect_uri) when is_binary(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "http", host: host} when host in @loopback_hosts -> true
      %URI{scheme: "https"} = uri -> allowlisted?(URI.to_string(uri))
      _ -> false
    end
  end

  def valid?(_), do: false

  defp allowlisted?(uri_string) do
    :dust
    |> Application.get_env(:mcp_redirect_uri_allowlist, [])
    |> Enum.any?(fn prefix -> String.starts_with?(uri_string, prefix) end)
  end
end
