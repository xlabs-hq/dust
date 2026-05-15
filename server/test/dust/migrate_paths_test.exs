defmodule Dust.MigratePathsTest do
  use ExUnit.Case, async: false

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
        "INSERT INTO store_entries VALUES ('users.alice', '{\"name\":\"alice\"}')"
      ],
      &(:ok = Exqlite.Sqlite3.execute(db, &1))
    )

    Exqlite.Sqlite3.close(db)
  end

  describe "run/1 (IEx-callable API)" do
    test "dry run returns summary without writing", %{store_root: root, db_path: db_path} do
      assert {:ok, summary} = Dust.MigratePaths.run(store_data_dir: root)
      assert summary.skipped == []
      assert [{^db_path, %{op_rewrites: 1, entry_rewrites: 1}}] = summary.migrated
      assert summary.errored == []

      # Confirm the DB itself wasn't touched.
      assert read_path(db_path, "store_entries") == "users.alice"
    end

    test "apply: true rewrites and marks user_version", %{store_root: root, db_path: db_path} do
      assert {:ok, summary} = Dust.MigratePaths.run(apply: true, store_data_dir: root)
      assert [{^db_path, %{op_rewrites: 1, entry_rewrites: 1}}] = summary.migrated

      assert read_path(db_path, "store_entries") == "users/alice"
      assert read_path(db_path, "store_ops") == "users/alice"
      assert user_version(db_path) == 3
    end

    test "already-migrated DB is reported as skipped", %{store_root: root, db_path: db_path} do
      {:ok, _} = Dust.MigratePaths.run(apply: true, store_data_dir: root)
      {:ok, summary} = Dust.MigratePaths.run(apply: true, store_data_dir: root)

      assert summary.skipped == [db_path]
      assert summary.migrated == []
    end

    test "returns error tuple when store_data_dir is unreadable", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "does-not-exist")

      assert {:error, {:bad_store_data_dir, msg}} =
               Dust.MigratePaths.run(store_data_dir: missing)

      assert msg =~ "does-not-exist"
    end
  end

  defp read_path(db_path, table) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path, [:readonly])
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT path FROM #{table} LIMIT 1")
    {:row, [p]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    p
  end

  defp user_version(db_path) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path, [:readonly])
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "PRAGMA user_version")
    {:row, [v]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Exqlite.Sqlite3.close(db)
    v
  end
end
