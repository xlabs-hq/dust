defmodule Dust.MCP.Tools.DustRemove do
  @moduledoc "MCP tool: remove a member from a set at a path."

  use GenMCP.Suite.Tool,
    name: "dust_remove",
    description:
      "Remove a member from a set at a path. No-op if the member doesn't exist or the set doesn't exist.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to the set"},
        member: %{description: "The value to remove from the set"}
      },
      required: [:store, :path, :member]
    },
    annotations: %{readOnlyHint: false}

  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path, "member" => member} = req.params.arguments
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
      case Dust.Sync.write(store.id, %{
             op: :remove,
             path: path,
             value: member,
             device_id: "mcp",
             client_op_id: Ecto.UUID.generate()
           }) do
        {:ok, op} ->
          {:result,
           MCP.call_tool_result(
             text: "Removed #{inspect(member)} from set at #{path} (seq: #{op.store_seq})"
           ), channel}

        {:error, reason} ->
          {:error, "Remove failed: #{inspect(reason)}", channel}
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
