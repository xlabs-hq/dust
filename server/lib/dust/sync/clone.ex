defmodule Dust.Sync.Clone do
  @moduledoc """
  Clone an entire store by duplicating its SQLite database file
  and creating a new store record in Postgres.
  """

  import Ecto.Query
  alias Dust.{Repo, Stores, Sync.StoreDB, Files.Blob}

  @doc """
  Clone `source` store into a new store named `target_name` within `organization`.

  Steps:
  1. Create a new store in Postgres (which also creates an empty SQLite file)
  2. Delete the empty SQLite file
  3. Use VACUUM INTO to copy the source DB into the target path
  4. Scan cloned DB for file entries and increment blob reference counts
  5. Copy metadata (current_seq, entry_count, op_count) from source to target

  Returns `{:ok, target_store}` or `{:error, reason}`.
  """
  def clone_store(source, organization, target_name) do
    with {:ok, target} <- Stores.create_store(organization, %{name: target_name}) do
      case do_clone(source, target) do
        {:ok, target} ->
          {:ok, target}

        {:error, reason} ->
          # Clean up the orphaned Postgres record and SQLite file
          Repo.delete(target)
          StoreDB.delete(target.id)
          {:error, reason}
      end
    end
  end

  defp do_clone(source, target) do
    with {:ok, target_path} <- StoreDB.path_for_id(target.id),
         :ok <- replace_with_clone(source.id, target_path),
         :ok <- increment_blob_refs(target.id),
         {:ok, target} <- copy_metadata(source, target) do
      {:ok, target}
    end
  end

  # Delete the empty SQLite file and replace it with a VACUUM INTO copy of the source.
  defp replace_with_clone(source_id, target_path) do
    File.rm(target_path)
    File.rm(target_path <> "-wal")
    File.rm(target_path <> "-shm")
    StoreDB.export(source_id, target_path)
  end

  # Scan file entries in the cloned DB and increment blob reference counts.
  defp increment_blob_refs(target_id) do
    case StoreDB.read_conn(target_id) do
      {:ok, conn} ->
        hashes = collect_file_hashes(conn)
        StoreDB.close(conn)
        bump_refs(hashes)

      {:error, _} = error ->
        error
    end
  end

  defp collect_file_hashes(conn) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "SELECT value FROM store_entries WHERE type = 'file'")

    hashes = collect_hashes(conn, stmt, [])
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    hashes
  end

  defp collect_hashes(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [json]} ->
        case Jason.decode(json) do
          {:ok, %{"hash" => hash}} -> collect_hashes(conn, stmt, [hash | acc])
          _ -> collect_hashes(conn, stmt, acc)
        end

      :done ->
        acc
    end
  end

  defp bump_refs([]), do: :ok

  defp bump_refs(hashes) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(hashes, fn hash ->
      from(b in Blob, where: b.hash == ^hash)
      |> Repo.update_all(inc: [reference_count: 1], set: [updated_at: now])
    end)

    :ok
  end

  # Copy metadata from source to target in Postgres.
  defp copy_metadata(source, target) do
    source = Stores.get_store!(source.id)

    from(s in Stores.Store, where: s.id == ^target.id)
    |> Repo.update_all(
      set: [
        current_seq: source.current_seq,
        entry_count: source.entry_count,
        op_count: source.op_count
      ]
    )

    {:ok, Stores.get_store!(target.id)}
  end
end
