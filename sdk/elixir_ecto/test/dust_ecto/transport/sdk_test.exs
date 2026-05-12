defmodule DustEcto.Transport.SDKTest do
  use ExUnit.Case, async: false

  alias DustEcto.Error
  alias DustEcto.Transport.SDK

  @store "test/store"

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} =
      Dust.SyncEngine.start_link(store: @store, cache: {Dust.Cache.Memory, []})

    Application.put_env(:dust_ecto, :store, @store)
    Application.put_env(:dust_ecto, :dust_facade, Dust)

    on_exit(fn ->
      Application.delete_env(:dust_ecto, :store)
      Application.delete_env(:dust_ecto, :dust_facade)
    end)

    :ok
  end

  describe "get/2 + exists?/2" do
    test "get returns the entry shape for a leaf" do
      :ok = Dust.SyncEngine.seed_entry(@store, "users/alice/name", "Alice", "string")

      assert {:ok, entry} = SDK.get(@store, "users/alice/name")
      assert entry.path == "users/alice/name"
      assert entry.value == "Alice"
      assert entry.type == "string"
    end

    test "get falls back to subtree assembly for an interior path" do
      :ok = Dust.SyncEngine.seed_entry(@store, "links/foo/title", "Foo", "string")
      :ok = Dust.SyncEngine.seed_entry(@store, "links/foo/url", "u", "string")

      assert {:ok, entry} = SDK.get(@store, "links/foo")
      assert entry.value == %{"title" => "Foo", "url" => "u"}
      assert entry.type == "map"
    end

    test "get returns {:error, :not_found} for missing path" do
      assert {:error, :not_found} = SDK.get(@store, "no.such.path")
    end

    test "exists? returns true/false" do
      :ok = Dust.SyncEngine.seed_entry(@store, "x", "y", "string")
      assert {:ok, true} = SDK.exists?(@store, "x")
      assert {:ok, false} = SDK.exists?(@store, "no.such.path")
    end
  end

  describe "put/4" do
    setup do
      Process.register(self(), Dust.Connection)
      :ok
    end

    test "writes a leaf and returns {:ok, %{store_seq: n}}" do
      task = Task.async(fn -> SDK.put(@store, "k", "v", []) end)
      store = @store
      assert_receive {:send_write, ^store, %{client_op_id: id}}, 500

      Dust.SyncEngine.handle_write_accepted(@store, id, 42)
      assert {:ok, %{store_seq: 42}} = Task.await(task, 500)
    end

    test "translates SDK :conflict to a DustEcto.Error{kind: :conflict}" do
      task = Task.async(fn -> SDK.put(@store, "k", "v", []) end)
      store = @store
      assert_receive {:send_write, ^store, %{client_op_id: id}}, 500

      Dust.SyncEngine.handle_write_rejected(@store, id, "conflict")

      assert {:error, %Error{kind: :conflict}} = Task.await(task, 500)
    end

    test "translates SDK :rate_limited to %Error{kind: :rate_limited, retryable?: true}" do
      task = Task.async(fn -> SDK.put(@store, "k", "v", []) end)
      store = @store
      assert_receive {:send_write, ^store, %{client_op_id: id}}, 500

      Dust.SyncEngine.handle_write_rejected(@store, id, "rate_limited")

      assert {:error, %Error{kind: :rate_limited, retryable?: true}} = Task.await(task, 500)
    end
  end

  describe "delete/3" do
    setup do
      Process.register(self(), Dust.Connection)
      :ok
    end

    test "deletes a leaf and returns {:ok, %{store_seq: n}}" do
      task = Task.async(fn -> SDK.delete(@store, "k", []) end)
      store = @store
      assert_receive {:send_write, ^store, %{op: :delete, client_op_id: id}}, 500

      Dust.SyncEngine.handle_write_accepted(@store, id, 17)
      assert {:ok, %{store_seq: 17}} = Task.await(task, 500)
    end
  end

  describe "subscribe/3 + unsubscribe/2" do
    test "registers a callback in :committed mode and returns a ref" do
      test_pid = self()
      assert {:ok, ref} = SDK.subscribe(@store, "**", fn evt -> send(test_pid, {:event, evt}) end)
      assert is_reference(ref)
      assert :ok = SDK.unsubscribe(@store, ref)
    end

    test "subscribed callback fires for committed events of others' writes" do
      test_pid = self()
      {:ok, _ref} = SDK.subscribe(@store, "**", fn evt -> send(test_pid, {:event, evt}) end)

      # Simulate an external server event (not our own write).
      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 5,
        "op" => "set",
        "path" => "k",
        "value" => "v",
        "device_id" => "other-dev",
        "client_op_id" => "external"
      })

      assert_receive {:event, %{committed: true, store_seq: 5, value: "v"}}, 200
    end
  end

  describe "batch_write/3" do
    test "returns :not_supported on the SDK transport" do
      assert {:error, %Error{kind: :not_supported}} = SDK.batch_write(@store, [], [])
    end
  end
end
