defmodule DustWeb.FileController do
  use DustWeb, :controller

  alias Dust.{Files, Stores}

  @doc """
  Download a blob by its content hash.

  Authenticates via Bearer token. Returns the raw file content with
  the correct content_type header.
  """
  def show(conn, %{"hash" => hash}) do
    with {:ok, store_token} <- authenticate(conn),
         true <- Stores.StoreToken.can_read?(store_token),
         {:ok, content} <- Files.download(hash) do
      blob = Files.get_blob(hash)
      content_type = (blob && blob.content_type) || "application/octet-stream"
      filename = blob && blob.filename

      conn
      |> put_resp_content_type(content_type)
      |> maybe_put_filename(filename)
      |> send_resp(200, content)
    else
      {:error, :invalid_token} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      false ->
        conn |> put_status(403) |> json(%{error: "forbidden"})
    end
  end

  defp authenticate(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> raw_token] -> Stores.authenticate_token(raw_token)
      _ -> {:error, :invalid_token}
    end
  end

  defp maybe_put_filename(conn, nil), do: conn

  defp maybe_put_filename(conn, filename) do
    put_resp_header(conn, "content-disposition", "inline; filename=\"#{filename}\"")
  end
end
