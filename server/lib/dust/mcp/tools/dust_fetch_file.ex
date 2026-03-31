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

  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    include_content = req.params.arguments["include_content"] == true
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
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

  defp resolve_store(full_name, store_token) do
    case Dust.Stores.get_store_by_full_name(full_name) do
      nil ->
        {:error, "Store not found: #{full_name}"}

      store ->
        if store.id == store_token.store_id do
          if Dust.Stores.StoreToken.can_read?(store_token) do
            {:ok, store}
          else
            {:error, "Token does not have read permission"}
          end
        else
          {:error, "Token does not have access to store: #{full_name}"}
        end
    end
  end
end
