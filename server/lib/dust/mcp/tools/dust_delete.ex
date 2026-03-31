defmodule Dust.MCP.Tools.DustDelete do
  @moduledoc "MCP tool: delete a path from a store."

  use GenMCP.Suite.Tool,
    name: "dust_delete",
    description: "Delete a path and all its descendants from a Dust store.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to delete"}
      },
      required: [:store, :path]
    },
    annotations: %{readOnlyHint: false, destructiveHint: true}

  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
      case Dust.Sync.write(store.id, %{
             op: :delete,
             path: path,
             device_id: "mcp",
             client_op_id: Ecto.UUID.generate()
           }) do
        {:ok, op} ->
          {:result, MCP.call_tool_result(text: "Deleted #{path} (seq: #{op.store_seq})"), channel}

        {:error, reason} ->
          {:error, "Delete failed: #{inspect(reason)}", channel}
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
          if Dust.Stores.StoreToken.can_write?(store_token) do
            {:ok, store}
          else
            {:error, "Token does not have write permission"}
          end
        else
          {:error, "Token does not have access to store: #{full_name}"}
        end
    end
  end
end
