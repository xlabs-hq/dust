defmodule Dust.MCP.Tools.DustPutFile do
  @moduledoc "MCP tool: upload a file and store a reference at a path."

  use GenMCP.Suite.Tool,
    name: "dust_put_file",
    description:
      "Upload a file (base64-encoded content) and store a content-addressed reference at a path in a Dust store.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to store the file reference"},
        content: %{type: :string, description: "Base64-encoded file content"},
        filename: %{type: :string, description: "Original filename (optional)"},
        content_type: %{
          type: :string,
          description: "MIME type (optional, default: application/octet-stream)"
        }
      },
      required: [:store, :path, :content]
    },
    annotations: %{readOnlyHint: false}

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path, "content" => base64_content} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :write),
         {:ok, content} <- Base.decode64(base64_content) do
      filename = req.params.arguments["filename"]
      content_type = req.params.arguments["content_type"] || "application/octet-stream"

      {:ok, ref} = Dust.Files.upload(content, filename: filename, content_type: content_type)

      case Dust.Sync.write(store.id, %{
             op: :put_file,
             path: path,
             value: ref,
             device_id: "mcp",
             client_op_id: Ecto.UUID.generate()
           }) do
        {:ok, op} ->
          {:result,
           MCP.call_tool_result(
             text:
               "Uploaded file to #{path} (hash: #{ref["hash"]}, size: #{ref["size"]}, seq: #{op.store_seq})"
           ), channel}

        {:error, reason} ->
          {:error, "Write failed: #{inspect(reason)}", channel}
      end
    else
      :error ->
        {:error, "Invalid base64 content", channel}

      {:error, reason} ->
        {:error, reason, channel}
    end
  end
end
