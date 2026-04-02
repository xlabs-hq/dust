defmodule Dust.Sync.ExportTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "export@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "exporttest"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store, org: org}
  end

  describe "to_jsonl_lines/2" do
    test "exports entries as JSONL lines with header", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "b", value: 2, device_id: "d", client_op_id: "o2"})

      lines = Dust.Sync.Export.to_jsonl_lines(store.id, "exporttest/blog")
      assert length(lines) == 3

      header = Jason.decode!(Enum.at(lines, 0))
      assert header["_header"] == true
      assert header["store"] == "exporttest/blog"
      assert header["entry_count"] == 2

      entry1 = Jason.decode!(Enum.at(lines, 1))
      assert entry1["path"] == "a"
      assert entry1["value"] == "1"
    end

    test "returns header-only for empty store", %{store: store} do
      lines = Dust.Sync.Export.to_jsonl_lines(store.id, "exporttest/blog")
      assert length(lines) == 1

      header = Jason.decode!(hd(lines))
      assert header["entry_count"] == 0
    end
  end

  describe "to_sqlite_file/2" do
    test "creates a valid SQLite export file", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "x", value: "v", device_id: "d", client_op_id: "o1"})

      dest = Path.join(System.tmp_dir!(), "test_export_#{System.unique_integer([:positive])}.db")
      on_exit(fn -> File.rm(dest) end)

      assert :ok = Dust.Sync.Export.to_sqlite_file(store.id, dest)
      assert File.exists?(dest)
      # Verify it's a valid SQLite file
      assert {:ok, conn} = Exqlite.Sqlite3.open(dest, [:readonly])
      Exqlite.Sqlite3.close(conn)
    end
  end
end
