defmodule Dust.MCP.Tools.DustFetchFile do
  @moduledoc "MCP tool: fetch file content or metadata by path."

  use GenMCP.Suite.Tool,
    name: "dust_fetch_file",
    description:
      "Fetch a file from a Dust store. Returns the file metadata. " <>
        "If include_content is true, also returns the base64-encoded file content.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{
          type: :string,
          description: "Dot-separated path where the file reference is stored"
        },
        include_content: %{
          type: :boolean,
          description: "Whether to include base64-encoded file content (default: false)"
        }
      },
      required: [:store, :path]
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    include_content = req.params.arguments["include_content"] == true
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :read) do
      case Dust.Sync.get_entry(store.id, path) do
        nil ->
          {:result, MCP.call_tool_result(text: Jason.encode!(nil)), channel}

        %{value: %{"_type" => "file", "hash" => hash} = ref} ->
          result =
            if include_content do
              case Dust.Files.download(hash) do
                {:ok, content} ->
                  Map.put(ref, "content", Base.encode64(content))

                {:error, :not_found} ->
                  Map.put(ref, "error", "blob_not_found")
              end
            else
              ref
            end

          {:result, MCP.call_tool_result(text: Jason.encode!(result)), channel}

        %{value: value} ->
          {:error, "Path #{path} is not a file (value: #{inspect(value)})", channel}
      end
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end
end
