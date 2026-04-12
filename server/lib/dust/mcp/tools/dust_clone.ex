defmodule Dust.MCP.Tools.DustClone do
  @moduledoc "MCP tool: clone a Dust store within the same organization."

  use GenMCP.Suite.Tool,
    name: "dust_clone",
    description: "Clone a Dust store within the same organization.",
    input_schema: %{
      type: :object,
      properties: %{
        source: %{type: :string, description: "Source store, full name (org/store)"},
        target_name: %{type: :string, description: "New store name"}
      },
      required: [:source, :target_name]
    }

  alias Dust.MCP.Authz
  alias Dust.Repo
  alias Dust.Sync
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"source" => source_full, "target_name" => target_name} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, source} <- Authz.authorize_store(principal, source_full, :read),
         source = Repo.preload(source, :organization),
         {:ok, target} <- Sync.Clone.clone_store(source, source.organization, target_name) do
      payload = %{store: "#{source.organization.slug}/#{target.name}", id: target.id}
      {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
    else
      {:error, :limit_exceeded, _meta} ->
        {:error, "Organization store limit exceeded", channel}

      {:error, reason} when is_binary(reason) ->
        {:error, reason, channel}

      {:error, reason} ->
        {:error, inspect(reason), channel}
    end
  end
end
