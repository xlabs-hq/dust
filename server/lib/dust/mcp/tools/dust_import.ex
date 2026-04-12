defmodule Dust.MCP.Tools.DustImport do
  @moduledoc "MCP tool: import JSONL entries into a Dust store."

  use GenMCP.Suite.Tool,
    name: "dust_import",
    description: "Import JSONL entries into a Dust store. Payload capped at 1 MB.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        payload: %{type: :string, description: "Newline-joined JSONL export payload"}
      },
      required: [:store, :payload]
    }

  alias Dust.MCP.Authz
  alias Dust.MCP.Principal
  alias Dust.Sync
  alias GenMCP.MCP

  @max_bytes 1_048_576

  @impl true
  def call(req, channel, _arg) do
    %{"store" => full_name, "payload" => payload} = req.params.arguments
    principal = channel.assigns.mcp_principal

    cond do
      byte_size(payload) > @max_bytes ->
        {:error, "Payload too large (#{byte_size(payload)} bytes); use the CLI: dust import",
         channel}

      true ->
        with {:ok, store} <- Authz.authorize_store(principal, full_name, :write),
             lines = String.split(payload, ~r/\r?\n/),
             {:ok, count} <- Sync.Import.from_jsonl(store.id, lines, device_id(principal)) do
          {:result,
           MCP.call_tool_result(text: Jason.encode!(%{ok: true, entries_imported: count})),
           channel}
        else
          {:error, reason} when is_binary(reason) -> {:error, reason, channel}
          {:error, reason} -> {:error, inspect(reason), channel}
        end
    end
  end

  defp device_id(%Principal{kind: :user_session, user: user}), do: "mcp:user:#{user.id}"
  defp device_id(%Principal{kind: :store_token, store_token: t}), do: "mcp:token:#{t.id}"
end
