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

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :read) do
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
end
