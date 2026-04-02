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
      |> Enum.map(&Jason.decode!/1)
      |> Enum.reject(fn decoded -> Map.get(decoded, "_header") == true end)

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
