defmodule DustWeb.Plugs.ApiTokenAuth do
  @moduledoc """
  Authenticates API requests via Bearer token and assigns the store token
  and its organization to the connection.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         {:ok, store_token} <- Dust.Stores.authenticate_token(raw_token) do
      conn
      |> assign(:store_token, store_token)
      |> assign(:organization, store_token.store.organization)
    else
      _ ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
