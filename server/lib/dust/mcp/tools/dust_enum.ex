defmodule Dust.MCP.Tools.DustEnum do
  @moduledoc "MCP tool: list entries matching a glob pattern."

  use GenMCP.Suite.Tool,
    name: "dust_enum",
    description:
      "List store entries matching a glob pattern. Use '*' to match a single segment, '**' to match any depth.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        pattern: %{
          type: :string,
          description: "Glob pattern to match paths (e.g. \"users.*\", \"**\")"
        }
      },
      required: [:store, :pattern]
    },
    annotations: %{readOnlyHint: true}

  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "pattern" => pattern} = req.params.arguments
    store_token = channel.assigns.store_token

    with {:ok, store} <- resolve_store(store_name, store_token) do
      entries = Dust.Sync.get_all_entries(store.id)

      matched =
        entries
        |> Enum.filter(fn entry -> glob_match?(entry.path, pattern) end)
        |> Enum.map(fn entry -> %{path: entry.path, value: entry.value, type: entry.type} end)

      {:result, MCP.call_tool_result(text: Jason.encode!(matched)), channel}
    else
      {:error, reason} ->
        {:error, reason, channel}
    end
  end

  @doc false
  def glob_match?(_path, "**"), do: true

  def glob_match?(path, pattern) do
    path_segments = String.split(path, ".")
    pattern_segments = String.split(pattern, ".")
    do_glob_match?(path_segments, pattern_segments)
  end

  defp do_glob_match?([], []), do: true
  defp do_glob_match?(_rest, ["**"]), do: true
  defp do_glob_match?([], _), do: false
  defp do_glob_match?(_path, []), do: false

  defp do_glob_match?([_p | path_rest], ["*" | pattern_rest]) do
    do_glob_match?(path_rest, pattern_rest)
  end

  defp do_glob_match?([seg | path_rest], [seg | pattern_rest]) do
    do_glob_match?(path_rest, pattern_rest)
  end

  defp do_glob_match?(_, _), do: false

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
