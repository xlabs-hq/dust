defmodule DustWeb.FileController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Files, Stores, Sync}
  alias DustWeb.Api.Refs

  operation :show,
    operation_id: "files.download",
    summary: "Download a blob by content hash",
    description:
      "Returns the raw blob bytes with the original `Content-Type` (and `Content-Disposition` if a filename was set). Only serves blobs referenced by the token's store.",
    tags: ["Files"],
    parameters: [
      hash: [
        in: :path,
        schema: %{type: :string},
        required: true,
        description: "SHA-256 content hash."
      ],
      _: Refs.parameter("RequestId")
    ],
    responses: [
      ok: [
        description: "Blob content (raw bytes).",
        content: %{
          "application/octet-stream" => %{
            schema: %{type: :string, format: :binary}
          }
        }
      ],
      unauthorized: Refs.unauthorized(),
      forbidden: Refs.forbidden(),
      not_found: Refs.not_found(),
      too_many_requests: Refs.rate_limited()
    ]

  def show(conn, %{"hash" => hash}) do
    store_token = conn.assigns.store_token

    with true <- Stores.StoreToken.can_read?(store_token),
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
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      false ->
        conn |> put_status(403) |> json(%{error: "forbidden"})
    end
  end

  defp maybe_put_filename(conn, nil), do: conn

  defp maybe_put_filename(conn, filename) do
    put_resp_header(conn, "content-disposition", "inline; filename=\"#{filename}\"")
  end
end
