defmodule Dust.MCP.Tools.DustStores do
  @moduledoc "MCP tool: list stores the principal can access."

  use GenMCP.Suite.Tool,
    name: "dust_stores",
    description: "List the stores this caller has access to.",
    input_schema: %{
      type: :object,
      properties: %{}
    },
    annotations: %{readOnlyHint: true}

  alias Dust.Accounts
  alias Dust.MCP.Principal
  alias Dust.Stores
  alias GenMCP.MCP

  @impl true
  def call(_req, channel, _arg) do
    principal = channel.assigns.mcp_principal
    payload = list_for(principal)
    {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
  end

  defp list_for(%Principal{kind: :store_token, store_token: token}) do
    store = token.store
    org = store.organization
    [%{name: "#{org.slug}/#{store.name}", status: store.status}]
  end

  defp list_for(%Principal{kind: :user_session, user: user}) do
    user
    |> Accounts.list_user_organizations()
    |> Enum.flat_map(fn org ->
      org
      |> Stores.list_stores()
      |> Enum.map(fn store ->
        %{name: "#{org.slug}/#{store.name}", status: store.status}
      end)
    end)
  end
end
