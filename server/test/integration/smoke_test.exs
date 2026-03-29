defmodule Dust.Integration.SmokeTest do
  use Dust.DataCase, async: false
  import Phoenix.ChannelTest
  import Dust.IntegrationHelpers

  @endpoint DustWeb.Endpoint

  # 1. Connect & auth
  describe "connect and auth" do
    test "valid token connects" do
      %{token: token, store: store} = create_test_store()
      {_socket, reply} = connect_client(token, store, "dev_1")
      assert is_integer(reply.store_seq)
    end

    test "invalid token rejects" do
      assert :error =
               Phoenix.ChannelTest.connect(DustWeb.StoreSocket, %{
                 "token" => "dust_tok_invalid",
                 "device_id" => "dev_1",
                 "capver" => 1
               })
    end
  end

  # 2. Basic CRUD
  describe "basic CRUD" do
    test "put, get, merge, delete round-trip" do
      %{token: token, store: store} = create_test_store("crud", "crud_store")
      {socket, _} = connect_client(token, store, "dev_1")

      # Put
      ref =
        push(socket, "write", %{
          "op" => "set",
          "path" => "posts.hello",
          "value" => %{"title" => "Hello"},
          "client_op_id" => "o1"
        })

      assert_reply ref, :ok, %{store_seq: 1}

      # Verify entry exists — get_entry unwraps _scalar, but maps stay as-is
      entry = Dust.Sync.get_entry(store.id, "posts.hello")
      assert entry.value == %{"title" => "Hello"}

      # Merge
      ref =
        push(socket, "write", %{
          "op" => "merge",
          "path" => "posts.hello",
          "value" => %{"body" => "World"},
          "client_op_id" => "o2"
        })

      assert_reply ref, :ok, %{store_seq: 2}

      # Merge creates child entry posts.hello.body with wrapped scalar
      # get_entry unwraps _scalar, so value is just "World"
      assert Dust.Sync.get_entry(store.id, "posts.hello.body").value == "World"

      # Delete
      ref =
        push(socket, "write", %{
          "op" => "delete",
          "path" => "posts.hello",
          "value" => nil,
          "client_op_id" => "o3"
        })

      assert_reply ref, :ok, %{store_seq: 3}

      assert Dust.Sync.get_entry(store.id, "posts.hello") == nil
    end
  end

  # 3. Two-client sync
  describe "two-client sync" do
    test "client A write appears on client B" do
      %{token: token, store: store} = create_test_store("sync2", "sync2_store")
      {socket_a, _} = connect_client(token, store, "dev_a")
      {_socket_b, _} = connect_client(token, store, "dev_b")

      push(socket_a, "write", %{
        "op" => "set",
        "path" => "x",
        "value" => "from_a",
        "client_op_id" => "o1"
      })

      # Client B should receive the broadcast
      assert_broadcast "event", %{path: "x", op: :set}
    end
  end

  # 4. Optimistic reconciliation
  describe "optimistic reconciliation" do
    test "write gets acknowledged with store_seq and broadcast includes client_op_id" do
      %{token: token, store: store} = create_test_store("optim", "optim_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref =
        push(socket, "write", %{
          "op" => "set",
          "path" => "x",
          "value" => "v",
          "client_op_id" => "my_op"
        })

      assert_reply ref, :ok, %{store_seq: seq}
      assert seq == 1

      # The broadcast includes client_op_id for reconciliation
      assert_broadcast "event", %{client_op_id: "my_op", store_seq: 1}
    end
  end

  # 5. Conflict: same path
  describe "conflict: same path" do
    test "later store_seq wins" do
      %{token: token, store: store} = create_test_store("conflict1", "conflict1_store")
      {socket_a, _} = connect_client(token, store, "dev_a")

      ref1 =
        push(socket_a, "write", %{
          "op" => "set",
          "path" => "x",
          "value" => "first",
          "client_op_id" => "o1"
        })

      assert_reply ref1, :ok, _

      ref2 =
        push(socket_a, "write", %{
          "op" => "set",
          "path" => "x",
          "value" => "second",
          "client_op_id" => "o2"
        })

      assert_reply ref2, :ok, _

      entry = Dust.Sync.get_entry(store.id, "x")
      # get_entry unwraps _scalar, so value is the raw string
      assert entry.value == "second"
      assert entry.seq == 2
    end
  end

  # 6. Conflict: ancestor vs descendant
  describe "conflict: ancestor vs descendant" do
    test "set on ancestor removes descendants" do
      %{token: token, store: store} = create_test_store("conflict2", "conflict2_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref1 =
        push(socket, "write", %{
          "op" => "set",
          "path" => "posts.hello.title",
          "value" => "Hi",
          "client_op_id" => "o1"
        })

      assert_reply ref1, :ok, _

      ref2 =
        push(socket, "write", %{
          "op" => "set",
          "path" => "posts.hello.body",
          "value" => "Body",
          "client_op_id" => "o2"
        })

      assert_reply ref2, :ok, _

      # Set ancestor replaces entire subtree
      ref3 =
        push(socket, "write", %{
          "op" => "set",
          "path" => "posts",
          "value" => %{"new" => "data"},
          "client_op_id" => "o3"
        })

      assert_reply ref3, :ok, _

      assert Dust.Sync.get_entry(store.id, "posts.hello.title") == nil
      assert Dust.Sync.get_entry(store.id, "posts.hello.body") == nil
      assert Dust.Sync.get_entry(store.id, "posts") != nil
    end
  end

  # 7. Conflict: merge vs set
  describe "conflict: merge vs set" do
    test "set after merge replaces everything" do
      %{token: token, store: store} = create_test_store("conflict3", "conflict3_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref1 =
        push(socket, "write", %{
          "op" => "merge",
          "path" => "settings",
          "value" => %{"locale" => "en"},
          "client_op_id" => "o1"
        })

      assert_reply ref1, :ok, _

      ref2 =
        push(socket, "write", %{
          "op" => "set",
          "path" => "settings",
          "value" => %{"theme" => "dark"},
          "client_op_id" => "o2"
        })

      assert_reply ref2, :ok, _

      # set replaced the merge — locale is gone
      assert Dust.Sync.get_entry(store.id, "settings.locale") == nil
      assert Dust.Sync.get_entry(store.id, "settings") != nil
    end
  end

  # 8. Catch-up sync
  describe "catch-up sync" do
    test "new client receives all prior ops" do
      %{token: token, store: store} = create_test_store("catchup", "catchup_store")

      # Write 10 ops directly (no client needed)
      for i <- 1..10 do
        Dust.Sync.write(store.id, %{
          op: :set,
          path: "key#{i}",
          value: "val#{i}",
          device_id: "d",
          client_op_id: "o#{i}"
        })
      end

      # Connect client with last_seq 0 — should get all 10
      {_socket, reply} = connect_client(token, store, "dev_late", 0)
      assert reply.store_seq == 10

      for i <- 1..10 do
        assert_push "event", %{store_seq: ^i}
      end
    end
  end

  # 9. Reconnect catch-up
  describe "reconnect catch-up" do
    test "client catches up from where it left off" do
      %{token: token, store: store} = create_test_store("reconnect", "reconnect_store")

      # Write 5 ops
      for i <- 1..5 do
        Dust.Sync.write(store.id, %{
          op: :set,
          path: "key#{i}",
          value: "v#{i}",
          device_id: "d",
          client_op_id: "o#{i}"
        })
      end

      # Client joins at seq 3 — should only get ops 4 and 5
      {_socket, reply} = connect_client(token, store, "dev_recon", 3)
      assert reply.store_seq == 5

      assert_push "event", %{store_seq: 4}
      assert_push "event", %{store_seq: 5}
      refute_push "event", %{store_seq: 1}
    end
  end

  # 10. Glob subscriptions
  describe "glob subscriptions" do
    test "broadcasts all events (glob filtering is SDK-side)" do
      %{token: token, store: store} = create_test_store("glob", "glob_store")
      {socket, _} = connect_client(token, store, "dev_1")

      # Write to various paths
      push(socket, "write", %{
        "op" => "set",
        "path" => "posts.hello",
        "value" => "v",
        "client_op_id" => "o1"
      })

      push(socket, "write", %{
        "op" => "set",
        "path" => "posts.hello.title",
        "value" => "v",
        "client_op_id" => "o2"
      })

      push(socket, "write", %{
        "op" => "set",
        "path" => "config.x",
        "value" => "v",
        "client_op_id" => "o3"
      })

      # All three broadcast (Channel broadcasts everything for the store)
      assert_broadcast "event", %{path: "posts.hello"}
      assert_broadcast "event", %{path: "posts.hello.title"}
      assert_broadcast "event", %{path: "config.x"}
    end
  end

  # 11. Enum
  describe "enum" do
    test "returns materialized entries matching pattern" do
      %{store: store} = create_test_store("enum", "enum_store")

      Dust.Sync.write(store.id, %{
        op: :set,
        path: "posts.a",
        value: "1",
        device_id: "d",
        client_op_id: "o1"
      })

      Dust.Sync.write(store.id, %{
        op: :set,
        path: "posts.b",
        value: "2",
        device_id: "d",
        client_op_id: "o2"
      })

      Dust.Sync.write(store.id, %{
        op: :set,
        path: "config.x",
        value: "3",
        device_id: "d",
        client_op_id: "o3"
      })

      entries = Dust.Sync.get_all_entries(store.id)
      posts = Enum.filter(entries, &String.starts_with?(&1.path, "posts."))
      assert length(posts) == 2
    end
  end

  # 12. Backpressure — deferred to when the SDK connection is fully wired
end
