defmodule DustWeb.Plugs.MCPAuth do
  @moduledoc """
  Authenticates MCP requests via Bearer token.

  Reads the `Authorization: Bearer dust_tok_...` header, calls
  `Dust.Stores.authenticate_token/1`, and assigns `:store_token` to the conn.
  Returns 401 if the token is missing or invalid.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw_token} <- extract_bearer_token(conn),
         {:ok, token} <- Dust.Stores.authenticate_token(raw_token) do
      assign(conn, :store_token, token)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :error
    end
  end
end
