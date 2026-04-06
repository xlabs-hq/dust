defmodule Dust.Sync.StoreDB do
  @moduledoc """
  Manages per-store SQLite database files.

  Each store's data (ops, entries, snapshots) lives in its own SQLite file.
  The Writer GenServer owns the write connection. Read-only connections
  are opened on demand for queries.
  """

  require Logger

  # Read at runtime so production can override via STORE_DATA_DIR env var
  defp store_data_dir_config, do: Application.get_env(:dust, :store_data_dir, "priv/stores")

  @schema_sql """
  PRAGMA journal_mode=WAL;

  CREATE TABLE IF NOT EXISTS store_ops (
    store_seq INTEGER PRIMARY KEY,
    op TEXT NOT NULL,
    path TEXT NOT NULL,
    value TEXT,
    type TEXT NOT NULL,
    device_id TEXT NOT NULL,
    client_op_id TEXT NOT NULL,
    inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE TABLE IF NOT EXISTS store_entries (
    path TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    type TEXT NOT NULL,
    seq INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS store_snapshots (
    snapshot_seq INTEGER PRIMARY KEY,
    snapshot_data TEXT NOT NULL,
    inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );
  """

  def store_data_dir, do: store_data_dir_config()

  @doc "Returns the SQLite file path for a store, given org slug and store name."
  def path(org_slug, store_name) do
    Path.join([store_data_dir_config(), org_slug, "#{store_name}.db"])
  end

  @doc "Looks up the store in Postgres and returns the SQLite file path."
  def path_for_id(store_id) do
    case lookup_store_meta(store_id) do
      {:ok, org_slug, store_name} -> {:ok, path(org_slug, store_name)}
      :error -> {:error, :store_not_found}
    end
  end

  @doc """
  Open a read-only SQLite connection for a store.

  Returns `{:ok, conn}` or `{:error, :not_found}` if the DB file doesn't exist.
  Caller is responsible for closing the connection with `close/1`.
  """
  def read_conn(store_id) do
    case path_for_id(store_id) do
      {:ok, db_path} ->
        if File.exists?(db_path) do
          {:ok, conn} = Exqlite.Sqlite3.open(db_path, [:readonly])
          {:ok, conn}
        else
          {:error, :not_found}
        end

      error ->
        error
    end
  end

  @doc "Close a SQLite connection."
  def close(conn) do
    Exqlite.Sqlite3.close(conn)
  end

  @doc """
  Create the SQLite file and schema tables for a store.
  No-op if the file already exists.
  """
  def ensure_created(store_id) do
    case path_for_id(store_id) do
      {:ok, db_path} ->
        File.mkdir_p!(Path.dirname(db_path))
        {:ok, conn} = Exqlite.Sqlite3.open(db_path)

        @schema_sql
        |> String.split(";")
        |> Enum.each(fn stmt ->
          stmt = String.trim(stmt)

          if stmt != "" do
            :ok = Exqlite.Sqlite3.execute(conn, stmt)
          end
        end)

        Exqlite.Sqlite3.close(conn)
        :ok

      error ->
        error
    end
  end

  @doc """
  Open a write connection for a store. Creates the file if needed.
  Used by the Writer GenServer.
  """
  def write_conn(store_id) do
    case path_for_id(store_id) do
      {:ok, db_path} ->
        File.mkdir_p!(Path.dirname(db_path))
        {:ok, conn} = Exqlite.Sqlite3.open(db_path)

        # Ensure schema exists and WAL mode is on
        @schema_sql
        |> String.split(";")
        |> Enum.each(fn stmt ->
          stmt = String.trim(stmt)
          if stmt != "", do: :ok = Exqlite.Sqlite3.execute(conn, stmt)
        end)

        {:ok, conn}

      error ->
        error
    end
  end

  @doc "Delete the SQLite file for a store."
  def delete(store_id) do
    case path_for_id(store_id) do
      {:ok, db_path} ->
        # Also delete WAL and SHM files
        File.rm(db_path)
        File.rm(db_path <> "-wal")
        File.rm(db_path <> "-shm")
        :ok

      _ ->
        :ok
    end
  end

  @doc "Export a store's SQLite DB to a standalone file using VACUUM INTO."
  def export(store_id, dest_path) do
    case path_for_id(store_id) do
      {:ok, db_path} ->
        {:ok, conn} = Exqlite.Sqlite3.open(db_path, [:readonly])
        :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{dest_path}'")
        Exqlite.Sqlite3.close(conn)
        :ok

      error ->
        error
    end
  end

  # Look up org_slug and store_name from Postgres for path computation.
  # Results are cached in the process dictionary for the lifetime of the caller.
  defp lookup_store_meta(store_id) do
    cache_key = {:store_meta, store_id}

    case Process.get(cache_key) do
      nil ->
        case do_lookup(store_id) do
          {:ok, _, _} = result ->
            Process.put(cache_key, result)
            result

          :error ->
            :error
        end

      result ->
        result
    end
  end

  defp do_lookup(store_id) do
    import Ecto.Query

    query =
      from(s in Dust.Stores.Store,
        join: o in assoc(s, :organization),
        where: s.id == ^store_id,
        select: {o.slug, s.name}
      )

    case Dust.Repo.one(query) do
      {org_slug, store_name} -> {:ok, org_slug, store_name}
      nil -> :error
    end
  end
end
