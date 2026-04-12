defmodule Dust.MCP.Tools.DustExport do
  @moduledoc "MCP tool: export a store as JSONL."

  use GenMCP.Suite.Tool,
    name: "dust_export",
    description: "Export a Dust store as a JSONL document. Capped at 1 MB.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"}
      },
      required: [:store]
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias Dust.Sync
  alias GenMCP.MCP

  @max_bytes 1_048_576

  @impl true
  def call(req, channel, _arg) do
    %{"store" => full_name} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, full_name, :read) do
      lines = Sync.Export.to_jsonl_lines(store.id, full_name)
      body = Enum.join(lines, "\n")

      if byte_size(body) > @max_bytes do
        {:error,
         "Store too large for MCP transport (#{byte_size(body)} bytes); use the CLI: dust export #{full_name}",
         channel}
      else
        payload = %{full_name: full_name, lines: lines}
        {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
      end
    else
      {:error, reason} -> {:error, reason, channel}
    end
  end
end
