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

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :write) do
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
end
