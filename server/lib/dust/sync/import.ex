defmodule Dust.Sync.Import do
  alias Dust.Sync

  @batch_size 100

  @doc """
  Imports entries from JSONL lines into a store.
  Each entry becomes a `set` op through the normal write path.
  Returns `{:ok, count}` with the number of entries imported.
  """
  def from_jsonl(store_id, lines, device_id) do
    entries =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn line -> line == "" end)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"_header" => true}} -> acc
          {:ok, %{"path" => _} = entry} -> [entry | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    entries
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      Enum.each(batch, fn entry ->
        Sync.write(store_id, %{
          op: :set,
          path: entry["path"],
          value: entry["value"],
          device_id: device_id,
          client_op_id: "import:#{entry["path"]}"
        })
      end)
    end)

    {:ok, length(entries)}
  end
end
