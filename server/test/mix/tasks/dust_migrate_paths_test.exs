defmodule Mix.Tasks.Dust.MigratePathsTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Dust.MigratePaths

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store_dir = Path.join(tmp_dir, "stores/acme")
    File.mkdir_p!(store_dir)
    db_path = Path.join(store_dir, "demo.db")
    seed_legacy_db(db_path)
    {:ok, store_root: Path.join(tmp_dir, "stores"), db_path: db_path}
  end

  defp seed_legacy_db(db_path) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path)

    Enum.each(
      [
        "CREATE TABLE store_ops (store_seq INTEGER PRIMARY KEY, path TEXT NOT NULL)",
        "CREATE TABLE store_entries (path TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "INSERT INTO store_ops VALUES (1, 'users.alice')",
        "INSERT INTO store_ops VALUES (2, 'users.bob')",
        "INSERT INTO store_entries VALUES ('users.alice', '{\"name\":\"alice\"}')",
        "INSERT INTO store_entries VALUES ('users.bob', '{\"name\":\"bob\"}')"
      ],
      &(:ok = Exqlite.Sqlite3.execute(db, &1))
    )

    Exqlite.Sqlite3.close(db)
  end

  defp paths_in(db_path, table) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path, [:readonly])
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT path FROM #{table} ORDER BY path")
    rows = collect(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    Enum.map(rows, fn [p] -> p end)
  end

  defp user_version(db_path) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path, [:readonly])
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "PRAGMA user_version")
    {:row, [v]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    v
  end

  defp collect(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> collect(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  test "dry run leaves DB untouched", %{store_root: root, db_path: db_path} do
    MigratePaths.run(["--store-data-dir", root])

    assert paths_in(db_path, "store_ops") == ["users.alice", "users.bob"]
    assert paths_in(db_path, "store_entries") == ["users.alice", "users.bob"]
    assert user_version(db_path) == 0
  end

  test "--apply rewrites paths and sets user_version", %{store_root: root, db_path: db_path} do
    MigratePaths.run(["--apply", "--store-data-dir", root])

    assert paths_in(db_path, "store_ops") == ["users/alice", "users/bob"]
    assert paths_in(db_path, "store_entries") == ["users/alice", "users/bob"]
    assert user_version(db_path) == 3
  end

  test "second --apply run is a no-op (already at capver 3)", %{
    store_root: root,
    db_path: db_path
  } do
    MigratePaths.run(["--apply", "--store-data-dir", root])
    MigratePaths.run(["--apply", "--store-data-dir", root])

    assert paths_in(db_path, "store_ops") == ["users/alice", "users/bob"]
    assert user_version(db_path) == 3
  end

  test "no-op when no DBs present", %{tmp_dir: tmp_dir} do
    empty = Path.join(tmp_dir, "empty")
    File.mkdir_p!(empty)
    # Just verify it doesn't raise.
    MigratePaths.run(["--apply", "--store-data-dir", empty])
  end
end
