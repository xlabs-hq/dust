defmodule Dust.Sync.ImportTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "import@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Test", slug: "importtest"})

    {:ok, store} = Stores.create_store(org, %{name: "target"})
    %{store: store}
  end

  describe "from_jsonl/3" do
    test "imports entries from JSONL lines", %{store: store} do
      lines = [
        ~s({"_header": true, "store": "importtest/source", "seq": 5, "entry_count": 2}),
        ~s({"path": "a", "value": "hello", "type": "string"}),
        ~s({"path": "b.c", "value": 42, "type": "integer"})
      ]

      assert {:ok, 2} = Sync.Import.from_jsonl(store.id, lines, "system:import")

      assert Sync.get_entry(store.id, "a").value == "hello"
      assert Sync.get_entry(store.id, "b.c").value == 42
    end

    test "overwrites existing keys (LWW)", %{store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "a",
        value: "old",
        device_id: "d",
        client_op_id: "o1"
      })

      lines = [
        ~s({"_header": true, "store": "x", "seq": 1, "entry_count": 1}),
        ~s({"path": "a", "value": "new", "type": "string"})
      ]

      assert {:ok, 1} = Sync.Import.from_jsonl(store.id, lines, "system:import")
      assert Sync.get_entry(store.id, "a").value == "new"
    end

    test "skips header line and blank lines", %{store: store} do
      lines = [
        ~s({"_header": true, "store": "x", "seq": 0, "entry_count": 1}),
        "",
        ~s({"path": "only", "value": true, "type": "boolean"}),
        ""
      ]

      assert {:ok, 1} = Sync.Import.from_jsonl(store.id, lines, "system:import")
    end

    test "preserves type from JSONL on import", %{store: store} do
      # Simulate a JSONL export that contains a file entry and a counter entry
      lines = [
        ~s({"_header": true, "store": "x", "seq": 2, "entry_count": 2}),
        ~s({"path": "avatar", "value": {"_type": "file", "hash": "sha256:abc123"}, "type": "file"}),
        ~s({"path": "views", "value": 42, "type": "counter"})
      ]

      assert {:ok, 2} = Sync.Import.from_jsonl(store.id, lines, "system:import")

      avatar = Sync.get_entry(store.id, "avatar")
      assert avatar != nil
      assert avatar.type == "file"

      views = Sync.get_entry(store.id, "views")
      assert views != nil
      assert views.type == "counter"
    end
  end
end
