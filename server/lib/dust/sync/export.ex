defmodule Dust.Sync.Export do
  alias Dust.Sync
  alias Dust.Sync.StoreDB
  alias DustProtocol.Path, as: DPath
  alias DustProtocol.Path.LegacyDot

  # Bumped to 3 with the segment-first path migration. The output is
  # always at this version: paths from pre-3 DBs are rewritten on the
  # way out so the dump is self-consistent.
  @path_schema_version 3

  @doc "Returns a list of JSONL lines: header + one line per entry."
  def to_jsonl_lines(store_id, full_name) do
    seq = Sync.current_seq(store_id)
    entries = Sync.get_all_entries(store_id)
    rewrite? = stored_path_schema_version(store_id) < @path_schema_version

    header =
      Jason.encode!(%{
        _header: true,
        store: full_name,
        seq: seq,
        entry_count: length(entries),
        path_schema_version: @path_schema_version,
        exported_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    entry_lines =
      Enum.map(entries, fn entry ->
        path = if rewrite?, do: canonicalize_legacy(entry.path), else: entry.path
        Jason.encode!(%{path: path, value: entry.value, type: entry.type})
      end)

    [header | entry_lines]
  end

  defp canonicalize_legacy(path) do
    with {:ok, segs} <- LegacyDot.parse(path),
         {:ok, canonical} <- DPath.render(segs) do
      canonical
    else
      _ -> path
    end
  end

  defp stored_path_schema_version(store_id) do
    case StoreDB.read_conn(store_id) do
      {:ok, conn} ->
        v = read_user_version(conn)
        StoreDB.close(conn)
        v

      _ ->
        0
    end
  end

  defp read_user_version(conn) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "PRAGMA user_version")

    v =
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, [n]} when is_integer(n) -> n
        _ -> 0
      end

    :ok = Exqlite.Sqlite3.release(conn, stmt)
    v
  end

  @doc "Exports a store's SQLite DB to a standalone file."
  def to_sqlite_file(store_id, dest_path) do
    StoreDB.export(store_id, dest_path)
  end
end
