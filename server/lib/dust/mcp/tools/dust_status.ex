defmodule Dust.MCP.Tools.DustStatus do
  @moduledoc "MCP tool: get sync status for a store."

  use GenMCP.Suite.Tool,
    name: "dust_status",
    description:
      "Get sync status for a store, including current sequence number and entry count.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"}
      },
      required: [:store]
    },
    annotations: %{readOnlyHint: true}

  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name} = req.params.arguments
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
      status = %{
        store: store_name,
        current_seq: Dust.Sync.current_seq(store.id),
        entry_count: Dust.Sync.entry_count(store.id)
      }

      {:result, MCP.call_tool_result(text: Jason.encode!(status)), channel}
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
