defmodule Dust.MCP.Tools.DustStores do
  @moduledoc "MCP tool: list stores the token has access to."

  use GenMCP.Suite.Tool,
    name: "dust_stores",
    description: "List the stores this token has access to.",
    input_schema: %{
      type: :object,
      properties: %{}
    },
    annotations: %{readOnlyHint: true}

  alias GenMCP.MCP

  @impl true
  def call(_req, channel, _arg) do
    store_token = channel.assigns.store_token
    store = store_token.store
    org = store.organization

    stores = [
      %{
        name: "#{org.slug}/#{store.name}",
        status: store.status
      }
    ]

    {:result, MCP.call_tool_result(text: Jason.encode!(stores)), channel}
  end
end
