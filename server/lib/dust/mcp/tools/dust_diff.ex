defmodule Dust.MCP.Tools.DustDiff do
  @moduledoc "MCP tool: get the diff of changes between two store sequence numbers."

  use GenMCP.Suite.Tool,
    name: "dust_diff",
    description: "Get the diff of changes between two store sequence numbers.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        from_seq: %{type: :integer, description: "Starting sequence number (inclusive)"},
        to_seq: %{type: :integer, description: "Optional ending sequence number"}
      },
      required: [:store, :from_seq]
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias Dust.Sync
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    args = req.params.arguments
    full_name = args["store"]
    from_seq = args["from_seq"]
    to_seq = args["to_seq"]
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, full_name, :read),
         {:ok, diff} <- Sync.Diff.changes(store.id, from_seq, to_seq) do
      payload = %{
        from_seq: diff.from_seq,
        to_seq: diff.to_seq,
        changes:
          Enum.map(diff.changes, fn c ->
            %{path: c.path, before: c.before, after: c.after}
          end)
      }

      {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
    else
      {:error, :compacted, _meta} ->
        {:error, "Diff range has been compacted; use a more recent from_seq", channel}

      {:error, reason} when is_binary(reason) ->
        {:error, reason, channel}

      {:error, reason} ->
        {:error, inspect(reason), channel}
    end
  end
end
