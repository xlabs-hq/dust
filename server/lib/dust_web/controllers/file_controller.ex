defmodule DustWeb.FileController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Files, Stores, Sync}

  operation :show,
    summary: "Download a blob by content hash",
    description:
      "Authenticates via Bearer token. Returns raw file content. Only serves blobs referenced by the token's store.",
    tags: ["Files"],
    parameters: [
      hash: [in: :path, schema: %{type: :string}, required: true]
    ],
    responses: [
      ok: [
        description: "Blob content (raw bytes)",
        content: %{"application/octet-stream" => %{schema: %{type: :string, format: :binary}}}
      ],
      unauthorized:
        {%{type: :object, properties: %{error: %{type: :string}}}, description: "Invalid token"},
      forbidden:
        {%{type: :object, properties: %{error: %{type: :string}}},
         description: "Token cannot read this blob"},
      not_found:
        {%{type: :object, properties: %{error: %{type: :string}}}, description: "Blob not found"}
    ]

  def show(conn, %{"hash" => hash}) do
    with {:ok, store_token} <- authenticate(conn),
         true <- Stores.StoreToken.can_read?(store_token),
         true <- Sync.has_file_ref?(store_token.store_id, hash),
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
