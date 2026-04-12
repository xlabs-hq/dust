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

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path, "member" => member} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :write) do
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
end
