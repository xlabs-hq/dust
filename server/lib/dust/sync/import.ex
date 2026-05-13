defmodule Dust.Sync.Import do
  alias Dust.Sync
  alias DustProtocol.Path, as: DPath
  alias DustProtocol.Path.LegacyDot

  @batch_size 100

  # Current dump format. See Dust.Sync.Export.
  @path_schema_version 3

  @doc """
  Import entries from JSONL lines into a store. Each entry becomes a
  `set` (or `put_file`) op through the normal write path.

  If the dump's header reports an older `path_schema_version` (or omits
  it), each entry's `path` is rewritten from dotted to slash-rendered
  before being written.

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
    {dump_version, lines_with_idx} = detect_version(lines)

    {imported, skipped, unparseable, failed_writes, _} =
      lines_with_idx
      |> Enum.reduce({0, 0, 0, [], 0}, fn {line, line_no}, {ok, sk, bad, failed, _batch_idx} ->
        case classify(line) do
          :blank ->
            {ok, sk + 1, bad, failed, 0}

          :header ->
            {ok, sk + 1, bad, failed, 0}

          {:entry, entry} ->
            case rewrite_if_legacy(entry, dump_version) do
              {:ok, entry} ->
                case write_entry(store_id, entry, device_id) do
                  :ok ->
                    {ok + 1, sk, bad, failed, 0}

                  {:error, reason} ->
                    {ok, sk, bad, [{line_no, entry["path"], reason} | failed], 0}
                end

              {:error, reason} ->
                {ok, sk, bad, [{line_no, entry["path"], reason} | failed], 0}
            end

          :unparseable ->
            {ok, sk, bad + 1, [{line_no, nil, :unparseable} | failed], 0}
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

  # Peek the first non-blank line for an _header with path_schema_version.
  # Returns {version, indexed_lines}; falls through with version=nil if the
  # first parseable line isn't a header.
  defp detect_version(lines) do
    indexed = Enum.with_index(lines, 1)

    version =
      Enum.find_value(indexed, fn {line, _} ->
        case String.trim(line) do
          "" ->
            nil

          trimmed ->
            case Jason.decode(trimmed) do
              {:ok, %{"_header" => true, "path_schema_version" => v}} when is_integer(v) -> v
              {:ok, %{"_header" => true}} -> :legacy
              _ -> :no_header
            end
        end
      end)

    {version, indexed}
  end

  defp rewrite_if_legacy(%{"path" => _path} = entry, version)
       when version == @path_schema_version do
    {:ok, entry}
  end

  defp rewrite_if_legacy(%{"path" => path} = entry, _version) do
    with {:ok, segs} <- LegacyDot.parse(path),
         {:ok, canonical} <- DPath.render(segs) do
      {:ok, Map.put(entry, "path", canonical)}
    else
      {:error, reason} -> {:error, {:bad_legacy_path, reason}}
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
