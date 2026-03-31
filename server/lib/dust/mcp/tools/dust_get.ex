defmodule Dust.MCP.Tools.DustGet do
  @moduledoc "MCP tool: read a value at a path in a store."

  use GenMCP.Suite.Tool,
    name: "dust_get",
    description:
      "Read a value at a path in a Dust store. Returns the entry value or null if not found.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to read (e.g. \"users.alice\")"}
      },
      required: [:store, :path]
    },
    annotations: %{readOnlyHint: true}

  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
      case Dust.Sync.get_entry(store.id, path) do
        nil ->
          {:result, MCP.call_tool_result(text: Jason.encode!(nil)), channel}

        entry ->
          {:result, MCP.call_tool_result(text: Jason.encode!(entry.value)), channel}
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
