defmodule Dust.Sync.RollbackTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}
  alias Dust.Sync.Rollback

  setup do
    {:ok, user} = Accounts.create_user(%{email: "rollback@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "rolltest"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store}
  end

  defp write!(store_id, op, path, value) do
    {:ok, op_result} =
      Sync.write(store_id, %{
        op: op,
        path: path,
        value: value,
        device_id: "test_device",
        client_op_id: Ecto.UUID.generate()
      })

    op_result
  end

  describe "rollback_path/3" do
    test "restores a previous value", %{store: store} do
      # Write initial value
      write!(store.id, :set, "posts.hello", %{"title" => "Hello"})
      # seq 1 has title "Hello"

      # Overwrite with new value
      write!(store.id, :set, "posts.hello", %{"title" => "Updated"})
      # seq 2 has title "Updated"

      # Verify current state
      assert Sync.get_entry(store.id, "posts.hello").value == %{"title" => "Updated"}

      # Rollback to seq 1
      {:ok, op} = Rollback.rollback_path(store.id, "posts.hello", 1)

      assert op.op == :set
      assert op.store_seq == 3
      assert Sync.get_entry(store.id, "posts.hello").value == %{"title" => "Hello"}
    end

    test "rollback to a point before the path existed results in delete", %{store: store} do
      # Write an unrelated op first to create seq 1
      write!(store.id, :set, "other", "value")

      # Write the path at seq 2
      write!(store.id, :set, "posts.new", "content")

      # Verify it exists
      assert Sync.get_entry(store.id, "posts.new") != nil

      # Rollback to seq 1 (before posts.new existed)
      {:ok, op} = Rollback.rollback_path(store.id, "posts.new", 1)

      assert op.op == :delete
      assert Sync.get_entry(store.id, "posts.new") == nil
    end

    test "creates a new op — forward operation", %{store: store} do
      write!(store.id, :set, "key", "v1")
      write!(store.id, :set, "key", "v2")

      current_seq = Sync.current_seq(store.id)
      assert current_seq == 2

      {:ok, op} = Rollback.rollback_path(store.id, "key", 1)

      # The rollback wrote a new op with a higher seq
      assert op.store_seq == 3
      assert op.store_seq > current_seq
    end

    test "rollback op has system:rollback device_id", %{store: store} do
      write!(store.id, :set, "key", "v1")
      write!(store.id, :set, "key", "v2")

      {:ok, op} = Rollback.rollback_path(store.id, "key", 1)

      assert op.device_id == "system:rollback"
      assert op.client_op_id =~ "rollback:1:"
    end

    test "returns noop when path already matches historical value", %{store: store} do
      write!(store.id, :set, "key", "v1")

      # Rollback to seq 1 — it's already at v1
      assert {:ok, :noop} = Rollback.rollback_path(store.id, "key", 1)
    end

    test "handles rollback after delete", %{store: store} do
      write!(store.id, :set, "key", "v1")
      write!(store.id, :delete, "key", nil)

      # Rollback to seq 1 when key had value "v1"
      {:ok, op} = Rollback.rollback_path(store.id, "key", 1)

      assert op.op == :set
      assert Sync.get_entry(store.id, "key").value == "v1"
    end

    test "returns error for seq beyond retention", %{store: store} do
      write!(store.id, :set, "key", "v1")

      # Earliest seq is 1, so seq 0 is beyond retention
      assert {:error, :beyond_retention} = Rollback.rollback_path(store.id, "key", 0)
    end

    test "returns error for store with no ops", %{store: store} do
      assert {:error, :no_ops} = Rollback.rollback_path(store.id, "key", 1)
    end

    test "rollback_path works for expanded map root", %{store: store} do
      write!(store.id, :set, "post", %{"title" => "Hello", "body" => "World"})
      write!(store.id, :set, "post", %{"title" => "Changed", "body" => "New"})

      {:ok, _op} = Rollback.rollback_path(store.id, "post", 1)

      entry = Sync.get_entry(store.id, "post")
      assert entry.value == %{"title" => "Hello", "body" => "World"}
    end

    test "rollback_store handles expanded maps correctly", %{store: store} do
      write!(store.id, :set, "post", %{"title" => "Hello"})
      # At seq 1: post.title = "Hello"

      write!(store.id, :set, "post", %{"title" => "Changed"})
      # At seq 2: post.title = "Changed"

      {:ok, count} = Rollback.rollback_store(store.id, 1)
      assert count == 1

      entry = Sync.get_entry(store.id, "post")
      assert entry.value == %{"title" => "Hello"}
    end
  end

  describe "rollback_store/2" do
    test "restores entire store state", %{store: store} do
      # Build up state: seq 1-3
      write!(store.id, :set, "a", "v1")
      write!(store.id, :set, "b", "v2")
      write!(store.id, :set, "c", "v3")
      # At seq 3: a=v1, b=v2, c=v3

      # Modify state: seq 4-6
      write!(store.id, :set, "a", "changed")
      write!(store.id, :delete, "b", nil)
      write!(store.id, :set, "d", "new")
      # At seq 6: a=changed, c=v3, d=new

      # Rollback to seq 3
      {:ok, count} = Rollback.rollback_store(store.id, 3)

      # Should have written ops for: a (changed -> v1), b (deleted -> v2), d (new -> deleted)
      assert count == 3

      # Verify state matches seq 3
      assert Sync.get_entry(store.id, "a").value == "v1"
      assert Sync.get_entry(store.id, "b").value == "v2"
      assert Sync.get_entry(store.id, "c").value == "v3"
      assert Sync.get_entry(store.id, "d") == nil
    end

    test "returns 0 when store already matches historical state", %{store: store} do
      write!(store.id, :set, "a", "v1")

      {:ok, count} = Rollback.rollback_store(store.id, 1)
      assert count == 0
    end

    test "preserves audit trail — rollback ops are in the log", %{store: store} do
      write!(store.id, :set, "key", "v1")
      write!(store.id, :set, "key", "v2")

      {:ok, _op} = Rollback.rollback_path(store.id, "key", 1)

      # All 3 ops should be in the log
      ops = Sync.get_ops_since(store.id, 0)
      assert length(ops) == 3

      rollback_op = List.last(ops)
      assert rollback_op.store_seq == 3
      assert rollback_op.device_id == "system:rollback"
      assert rollback_op.op == :set
    end

    test "returns error for seq beyond retention", %{store: store} do
      write!(store.id, :set, "key", "v1")

      assert {:error, :beyond_retention} = Rollback.rollback_store(store.id, 0)
    end

    test "handles store-level rollback with merge ops in history", %{store: store} do
      write!(store.id, :set, "profile.name", "Alice")
      write!(store.id, :merge, "profile", %{"age" => 30})
      # At seq 2: profile.name=Alice, profile.age=30

      write!(store.id, :set, "profile.name", "Bob")
      # At seq 3: profile.name=Bob, profile.age=30

      {:ok, count} = Rollback.rollback_store(store.id, 2)

      assert count == 1
      assert Sync.get_entry(store.id, "profile.name").value == "Alice"
      assert Sync.get_entry(store.id, "profile.age").value == 30
    end
  end

  describe "compute_historical_value/3" do
    test "returns nil when path never existed", %{store: store} do
      write!(store.id, :set, "other", "val")

      assert Rollback.compute_historical_value(store.id, "nonexistent", 1) == nil
    end

    test "returns nil when path was deleted at that seq", %{store: store} do
      write!(store.id, :set, "key", "v1")
      write!(store.id, :delete, "key", nil)

      assert Rollback.compute_historical_value(store.id, "key", 2) == nil
    end

    test "resolves value from ancestor set op", %{store: store} do
      # set("docs", %{readme: "hello"}) creates one op at path "docs"
      # but materializes an entry at "docs" with value %{readme: "hello"}
      write!(store.id, :set, "docs", %{"readme" => "hello", "license" => "MIT"})

      # Now set a direct child — creates a new op at "docs.readme"
      write!(store.id, :set, "docs.readme", "updated")

      # Historical value of "docs.readme" at seq 1 should be "hello"
      # (extracted from the ancestor set op's map value)
      value = Rollback.compute_historical_value(store.id, "docs.readme", 1)
      assert value == %{"_scalar" => "hello"}
    end

    test "ancestor delete removes descendant value", %{store: store} do
      write!(store.id, :set, "docs.readme", "hello")
      write!(store.id, :delete, "docs", nil)

      # At seq 2, "docs" was deleted — so "docs.readme" should be nil
      value = Rollback.compute_historical_value(store.id, "docs.readme", 2)
      assert value == nil
    end

    test "returns value from the most recent set at or before to_seq", %{store: store} do
      write!(store.id, :set, "key", "v1")
      write!(store.id, :set, "key", "v2")
      write!(store.id, :set, "key", "v3")

      value = Rollback.compute_historical_value(store.id, "key", 2)
      assert value == %{"_scalar" => "v2"}
    end
  end

  describe "compute_historical_state/2" do
    test "replays ops to build state", %{store: store} do
      write!(store.id, :set, "a", "1")
      write!(store.id, :set, "b", "2")
      write!(store.id, :delete, "a", nil)
      write!(store.id, :set, "c", "3")

      state = Rollback.compute_historical_state(store.id, 4)

      assert state == %{
               "b" => %{"_scalar" => "2"},
               "c" => %{"_scalar" => "3"}
             }

      # At seq 2, both a and b should exist
      state_at_2 = Rollback.compute_historical_state(store.id, 2)

      assert state_at_2 == %{
               "a" => %{"_scalar" => "1"},
               "b" => %{"_scalar" => "2"}
             }
    end
  end

  describe "validate_retention/2" do
    test "returns :ok for valid seq", %{store: store} do
      write!(store.id, :set, "key", "v1")

      assert :ok = Rollback.validate_retention(store.id, 1)
    end

    test "returns error for seq before earliest", %{store: store} do
      write!(store.id, :set, "key", "v1")

      assert {:error, :beyond_retention} = Rollback.validate_retention(store.id, 0)
    end

    test "returns error for empty store", %{store: store} do
      assert {:error, :no_ops} = Rollback.validate_retention(store.id, 1)
    end
  end
end
