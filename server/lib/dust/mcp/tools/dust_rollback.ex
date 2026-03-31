defmodule Dust.MCP.Tools.DustRollback do
  @moduledoc "MCP tool: rollback a path or entire store to a previous store_seq."

  use GenMCP.Suite.Tool,
    name: "dust_rollback",
    description:
      "Rollback a path or entire store to a previous store_seq. " <>
        "Rollback is a forward operation — it writes new ops that restore state, preserving the audit trail.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{
          type: :string,
          description:
            "Dot-separated path to rollback (e.g. \"posts.hello\"). Omit for store-level rollback."
        },
        to_seq: %{
          type: :integer,
          description: "The store_seq to rollback to. State will match what it looked like at this seq."
        }
      },
      required: [:store, :to_seq]
    },
    annotations: %{readOnlyHint: false}

  alias GenMCP.MCP
  alias Dust.Sync.Rollback

  @impl true
  def call(req, channel, _arg) do
    args = req.params.arguments
    store_name = args["store"]
    to_seq = args["to_seq"]
    path = args["path"]
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
      result =
        if path do
          rollback_path(store.id, path, to_seq)
        else
          rollback_store(store.id, to_seq)
        end

      case result do
        {:ok, message} ->
          {:result, MCP.call_tool_result(text: message), channel}

        {:error, reason} ->
          {:error, "Rollback failed: #{reason}", channel}
      end
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end

  defp rollback_path(store_id, path, to_seq) do
    case Rollback.rollback_path(store_id, path, to_seq) do
      {:ok, :noop} ->
        {:ok, "No change needed — #{path} already matches state at seq #{to_seq}"}

      {:ok, op} ->
        {:ok, "Rolled back #{path} to seq #{to_seq} (new seq: #{op.store_seq})"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rollback_store(store_id, to_seq) do
    case Rollback.rollback_store(store_id, to_seq) do
      {:ok, 0} ->
        {:ok, "No change needed — store already matches state at seq #{to_seq}"}

      {:ok, count} ->
        {:ok, "Rolled back store to seq #{to_seq} (#{count} ops written)"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_store(full_name, store_token) do
    case Dust.Stores.get_store_by_full_name(full_name) do
      nil ->
        {:error, "Store not found: #{full_name}"}

      store ->
        if store.id == store_token.store_id do
          if Dust.Stores.StoreToken.can_write?(store_token) do
            {:ok, store}
          else
            {:error, "Token does not have write permission"}
          end
        else
          {:error, "Token does not have access to store: #{full_name}"}
        end
    end
  end
end
