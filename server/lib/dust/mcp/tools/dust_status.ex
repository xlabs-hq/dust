defmodule Dust.MCP.Tools.DustStatus do
  @moduledoc "MCP tool: get sync status for a store."

  use GenMCP.Suite.Tool,
    name: "dust_status",
    description:
      "Get sync status for a store, including current sequence number and entry count.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"}
      }
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias Dust.MCP.Principal
  alias Dust.Sync
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    principal = channel.assigns.mcp_principal
    store_arg = Map.get(req.params.arguments, "store")

    with {:ok, store, full_name} <- resolve(principal, store_arg) do
      status = %{
        store: full_name,
        current_seq: Sync.current_seq(store.id),
        entry_count: Sync.entry_count(store.id)
      }

      {:result, MCP.call_tool_result(text: Jason.encode!(status)), channel}
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end

  defp resolve(%Principal{kind: :store_token, store_token: token}, nil) do
    store = token.store
    org = store.organization
    {:ok, store, "#{org.slug}/#{store.name}"}
  end

  defp resolve(%Principal{kind: :store_token} = principal, full_name)
       when is_binary(full_name) do
    with {:ok, store} <- Authz.authorize_store(principal, full_name, :read) do
      {:ok, store, full_name}
    end
  end

  defp resolve(%Principal{kind: :user_session}, nil) do
    {:error, "store argument is required for user-session callers"}
  end

  defp resolve(%Principal{kind: :user_session} = principal, full_name)
       when is_binary(full_name) do
    with {:ok, store} <- Authz.authorize_store(principal, full_name, :read) do
      {:ok, store, full_name}
    end
  end
end
