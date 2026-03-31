defmodule Dust.MCP.Tools.DustLog do
  @moduledoc "MCP tool: query the audit log (operation history) for a store."

  use GenMCP.Suite.Tool,
    name: "dust_log",
    description:
      "Query the operation history (audit log) for a store. Supports filtering by path, device, op type, and time range.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{
          type: :string,
          description: "Filter by path (exact or wildcard, e.g. \"users.*\")"
        },
        device_id: %{type: :string, description: "Filter by device ID"},
        op: %{
          type: :string,
          description: "Filter by op type: set, delete, or merge",
          enum: ["set", "delete", "merge"]
        },
        since: %{
          type: :string,
          description: "ISO 8601 datetime; only ops at or after this time"
        },
        limit: %{
          type: :integer,
          description: "Max results to return (default 50, max 200)"
        }
      },
      required: [:store]
    },
    annotations: %{readOnlyHint: true}

  alias GenMCP.MCP
  alias Dust.Sync.Audit

  @impl true
  def call(req, channel, _arg) do
    args = req.params.arguments
    store_name = args["store"]
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
      limit = min(args["limit"] || 50, 200)

      opts =
        [limit: limit]
        |> maybe_add(:path, args["path"])
        |> maybe_add(:device_id, args["device_id"])
        |> maybe_add(:op, args["op"])
        |> maybe_add(:since, args["since"])

      ops = Audit.query_ops(store.id, opts)

      result =
        Enum.map(ops, fn op ->
          %{
            seq: op.store_seq,
            op: op.op,
            path: op.path,
            value: op.value,
            device_id: op.device_id,
            at: op.inserted_at
          }
        end)

      {:result, MCP.call_tool_result(text: Jason.encode!(result)), channel}
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp resolve_store(full_name, store_token) do
    case Dust.Stores.get_store_by_full_name(full_name) do
      nil ->
        {:error, "Store not found: #{full_name}"}

      store ->
        if store.id == store_token.store_id do
          if Dust.Stores.StoreToken.can_read?(store_token) do
            {:ok, store}
          else
            {:error, "Token does not have read permission"}
          end
        else
          {:error, "Token does not have access to store: #{full_name}"}
        end
    end
  end
end
