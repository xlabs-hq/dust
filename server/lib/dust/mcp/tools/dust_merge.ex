defmodule Dust.MCP.Tools.DustMerge do
  @moduledoc "MCP tool: merge keys into a map at a path."

  use GenMCP.Suite.Tool,
    name: "dust_merge",
    description: "Merge keys into an existing map at a path. The value must be a JSON object.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to merge into"},
        value: %{type: :object, description: "Map of keys to merge"}
      },
      required: [:store, :path, :value]
    },
    annotations: %{readOnlyHint: false}

  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path, "value" => value} = req.params.arguments
    store_token = channel.assigns.store_token

    unless is_map(value) do
      {:error, "Value must be a JSON object for merge operations", channel}
    end

    with {:ok, store} <- resolve_store(store_name, store_token) do
      case Dust.Sync.write(store.id, %{
             op: :merge,
             path: path,
             value: value,
             device_id: "mcp",
             client_op_id: Ecto.UUID.generate()
           }) do
        {:ok, op} ->
          {:result, MCP.call_tool_result(text: "Merged into #{path} (seq: #{op.store_seq})"),
           channel}

        {:error, reason} ->
          {:error, "Merge failed: #{inspect(reason)}", channel}
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
