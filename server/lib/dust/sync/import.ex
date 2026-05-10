defmodule Dust.Sync.Import do
  alias Dust.Sync

  @batch_size 100

  @doc """
  Import entries from JSONL lines into a store. Each entry becomes a
  `set` (or `put_file`) op through the normal write path.

  Returns a structured summary so the caller can surface accurate
  numbers and per-line errors:

      {:ok, %{
        imported: integer,           # writes that returned :ok
        skipped: integer,            # blank lines, header rows
        failed: [%{                  # parse + write failures
          line: integer,             # 1-indexed source line number
          reason: term,              # tagged failure reason
          path: binary | nil         # path if known
        }],
        unparseable: integer         # malformed JSON or missing path
      }}

  Header rows (`{"_header": true}`) and blank lines are silently
  skipped (counted under `skipped`).
  """
  def from_jsonl(store_id, lines, device_id) do
    {imported, skipped, unparseable, failed_writes, _} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0, 0, [], 0}, fn {line, line_no},
                                          {ok, sk, bad, failed, _batch_idx} ->
        case classify(line) do
          :blank ->
            {ok, sk + 1, bad, failed, 0}

          :header ->
            {ok, sk + 1, bad, failed, 0}

          {:entry, entry} ->
            case write_entry(store_id, entry, device_id) do
              :ok -> {ok + 1, sk, bad, failed, 0}
              {:error, reason} -> {ok, sk, bad, [{line_no, entry["path"], reason} | failed], 0}
            end

          :unparseable ->
            {ok, sk, bad + 1,
             [{line_no, nil, :unparseable} | failed], 0}
        end
      end)

    failed =
      failed_writes
      |> Enum.reverse()
      |> Enum.map(fn {line_no, path, reason} ->
        %{line: line_no, path: path, reason: reason}
      end)

    {:ok,
     %{
       imported: imported,
       skipped: skipped,
       unparseable: unparseable,
       failed: failed
     }}
  end

  defp classify(line) do
    case String.trim(line) do
      "" ->
        :blank

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{"_header" => true}} -> :header
          {:ok, %{"path" => p} = entry} when is_binary(p) and p != "" -> {:entry, entry}
          _ -> :unparseable
        end
    end
  end

  defp write_entry(store_id, entry, device_id) do
    op = if entry["type"] == "file", do: :put_file, else: :set

    attrs = %{
      op: op,
      path: entry["path"],
      value: entry["value"],
      device_id: device_id,
      client_op_id: "import:#{entry["path"]}"
    }

    attrs = if entry["type"], do: Map.put(attrs, :type, entry["type"]), else: attrs

    case Sync.write(store_id, attrs) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      {:error, reason, _} -> {:error, reason}
      other -> {:error, {:unexpected_write_result, other}}
    end
  end

  # Silence the @batch_size warning while we keep it for future use.
  def batch_size, do: @batch_size
end
