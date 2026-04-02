defmodule Dust.Sync.Export do
  alias Dust.Sync
  alias Dust.Sync.StoreDB

  @doc "Returns a list of JSONL lines: header + one line per entry."
  def to_jsonl_lines(store_id, full_name) do
    seq = Sync.current_seq(store_id)
    entries = Sync.get_all_entries(store_id)

    header =
      Jason.encode!(%{
        _header: true,
        store: full_name,
        seq: seq,
        entry_count: length(entries),
        exported_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    entry_lines =
      Enum.map(entries, fn entry ->
        Jason.encode!(%{path: entry.path, value: entry.value, type: entry.type})
      end)

    [header | entry_lines]
  end

  @doc "Exports a store's SQLite DB to a standalone file."
  def to_sqlite_file(store_id, dest_path) do
    StoreDB.export(store_id, dest_path)
  end
end
