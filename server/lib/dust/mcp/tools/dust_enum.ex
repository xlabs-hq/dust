defmodule Dust.MCP.Tools.DustEnum do
  @moduledoc "MCP tool: list entries matching a glob pattern."

  use GenMCP.Suite.Tool,
    name: "dust_enum",
    description:
      "List store entries matching a slash-separated glob pattern. Use '*' to match a single segment, '**' to match any depth.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        pattern: %{
          type: :string,
          description: "Glob pattern to match paths (e.g. \"users/*\", \"**\")"
        }
      },
      required: [:store, :pattern]
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias DustProtocol.Glob
  alias DustProtocol.Path
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "pattern" => pattern} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :read),
         {:ok, compiled} <- Glob.compile(pattern) do
      entries = Dust.Sync.get_all_entries(store.id)

      matched =
        entries
        |> Enum.filter(fn entry ->
          case Path.parse_rendered(entry.path) do
            {:ok, segs} -> Glob.match?(compiled, segs)
            _ -> false
          end
        end)
        |> Enum.map(fn entry -> %{path: entry.path, value: entry.value, type: entry.type} end)

      {:result, MCP.call_tool_result(text: Jason.encode!(matched)), channel}
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end
end
