defmodule Dust.MCP.Tools.DustIncrement do
  @moduledoc "MCP tool: increment a counter at a path."

  use GenMCP.Suite.Tool,
    name: "dust_increment",
    description:
      "Increment a counter at a path. Creates the counter at 0 if it doesn't exist. Delta defaults to 1.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to the counter"},
        delta: %{type: :number, description: "Amount to increment by (default: 1)"}
      },
      required: [:store, :path]
    },
    annotations: %{readOnlyHint: false}

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    delta = Map.get(req.params.arguments, "delta", 1)
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :write) do
      case Dust.Sync.write(store.id, %{
             op: :increment,
             path: path,
             value: delta,
             device_id: "mcp",
             client_op_id: Ecto.UUID.generate()
           }) do
        {:ok, op} ->
          {:result,
           MCP.call_tool_result(text: "Incremented #{path} by #{delta} (seq: #{op.store_seq})"),
           channel}

        {:error, reason} ->
          {:error, "Increment failed: #{inspect(reason)}", channel}
      end
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end
end
