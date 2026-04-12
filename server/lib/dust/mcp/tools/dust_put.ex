defmodule Dust.MCP.Tools.DustPut do
  @moduledoc "MCP tool: write a value at a path in a store."

  use GenMCP.Suite.Tool,
    name: "dust_put",
    description: "Write a value at a path in a Dust store. Overwrites any existing value.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to write (e.g. \"users.alice\")"},
        value: %{description: "The value to write (any JSON type)"}
      },
      required: [:store, :path, :value]
    },
    annotations: %{readOnlyHint: false}

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path, "value" => value} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :write) do
      case Dust.Sync.write(store.id, %{
             op: :set,
             path: path,
             value: value,
             device_id: "mcp",
             client_op_id: Ecto.UUID.generate()
           }) do
        {:ok, op} ->
          {:result, MCP.call_tool_result(text: "Wrote to #{path} (seq: #{op.store_seq})"),
           channel}

        {:error, reason} ->
          {:error, "Write failed: #{inspect(reason)}", channel}
      end
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end
end
