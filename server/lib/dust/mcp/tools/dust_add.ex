defmodule Dust.MCP.Tools.DustAdd do
  @moduledoc "MCP tool: add a member to a set at a path."

  use GenMCP.Suite.Tool,
    name: "dust_add",
    description:
      "Add a member to a set at a path. Creates the set if it doesn't exist. Idempotent — adding a duplicate is a no-op.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to the set"},
        member: %{description: "The value to add to the set"}
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
             op: :add,
             path: path,
             value: member,
             device_id: "mcp",
             client_op_id: Ecto.UUID.generate()
           }) do
        {:ok, op} ->
          {:result,
           MCP.call_tool_result(
             text: "Added #{inspect(member)} to set at #{path} (seq: #{op.store_seq})"
           ), channel}

        {:error, reason} ->
          {:error, "Add failed: #{inspect(reason)}", channel}
      end
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end
end
