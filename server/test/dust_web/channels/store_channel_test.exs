defmodule DustWeb.StoreChannelTest do
  use Dust.DataCase, async: false
  import Phoenix.ChannelTest

  alias Dust.{Accounts, Stores, Sync}

  @endpoint DustWeb.Endpoint

  setup do
    {:ok, user} = Accounts.create_user(%{email: "channel@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "test"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "rw",
        read: true,
        write: true,
        created_by_id: user.id
      })

    {:ok, store_token} = Stores.authenticate_token(token.raw_token)

    socket =
      socket(DustWeb.StoreSocket, "test", %{
        store_token: store_token,
        device_id: "dev_test",
        capver: 1
      })

    %{socket: socket, store: store, token: token}
  end

  describe "join" do
    test "joins with valid store and receives catch-up", %{socket: socket, store: store} do
      # Write some data first
      Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})

      {:ok, reply, _socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      assert reply.store_seq == 2

      # Should receive catch-up events followed by catch_up_complete
      assert_push "event", %{store_seq: 1, path: "a"}
      assert_push "event", %{store_seq: 2, path: "b"}
      assert_push "catch_up_complete", %{through_seq: 2}
    end

    test "joins with store full name (org/name)", %{socket: socket, store: store} do
      Sync.write(store.id, %{op: :set, path: "x", value: "1", device_id: "d", client_op_id: "o1"})

      {:ok, reply, _socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:test/blog", %{
          "last_store_seq" => 0
        })

      assert reply.store_seq == 1
      assert_push "event", %{store_seq: 1, path: "x"}
    end

    test "rejects join for wrong store_id", %{socket: socket} do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 DustWeb.StoreChannel,
                 "store:00000000-0000-0000-0000-000000000000",
                 %{"last_store_seq" => 0}
               )
    end

    test "rejects join for nonexistent store name", %{socket: socket} do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 DustWeb.StoreChannel,
                 "store:nonexistent/store",
                 %{"last_store_seq" => 0}
               )
    end
  end

  describe "put_file" do
    setup %{socket: socket, store: store} do
      # Clean up test blobs directory
      blob_dir = Dust.Files.blob_dir()
      File.rm_rf!(blob_dir)
      on_exit(fn -> File.rm_rf!(blob_dir) end)

      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      %{joined_socket: socket}
    end

    test "uploads a file and stores reference", %{joined_socket: socket} do
      content = "hello world"
      base64 = Base.encode64(content)

      ref =
        push(socket, "put_file", %{
          "path" => "docs.readme",
          "content" => base64,
          "filename" => "readme.txt",
          "content_type" => "text/plain",
          "client_op_id" => "file_op_1"
        })

      assert_reply ref, :ok, %{store_seq: 1, hash: hash}
      assert String.starts_with?(hash, "sha256:")

      # Verify the event was broadcast
      assert_broadcast "event", %{
        store_seq: 1,
        op: :put_file,
        path: "docs.readme",
        value: %{"_type" => "file", "hash" => ^hash}
      }

      # Verify blob exists on disk
      assert Dust.Files.exists?(hash)
      assert {:ok, ^content} = Dust.Files.download(hash)
    end

    test "rejects invalid base64", %{joined_socket: socket} do
      ref =
        push(socket, "put_file", %{
          "path" => "docs.bad",
          "content" => "not valid base64!!!",
          "client_op_id" => "file_op_2"
        })

      assert_reply ref, :error, %{reason: "invalid_base64"}
    end

    test "rejects invalid path", %{joined_socket: socket} do
      ref =
        push(socket, "put_file", %{
          "path" => "docs..bad",
          "content" => Base.encode64("test"),
          "client_op_id" => "file_op_3"
        })

      assert_reply ref, :error, %{reason: "empty_segment"}
    end
  end

  describe "write" do
    test "write broadcasts to all subscribers", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      ref =
        push(socket, "write", %{
          "op" => "set",
          "path" => "posts.hello",
          "value" => %{"title" => "Hello"},
          "client_op_id" => "op_1"
        })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, op: :set, path: "posts.hello"}
    end

    test "rejects invalid path", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      ref =
        push(socket, "write", %{
          "op" => "set",
          "path" => "posts..hello",
          "value" => "v",
          "client_op_id" => "o1"
        })

      assert_reply ref, :error, %{reason: "empty_segment"}
    end

    test "rejects missing path", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      ref =
        push(socket, "write", %{
          "op" => "set",
          "value" => "v",
          "client_op_id" => "o1"
        })

      assert_reply ref, :error, %{reason: "missing_path"}
    end

    test "increment broadcasts materialized value, not delta", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      # First increment: 0 + 5 = 5
      ref = push(socket, "write", %{
        "op" => "increment",
        "path" => "stats.views",
        "value" => 5,
        "client_op_id" => "inc_1"
      })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, path: "stats.views", value: 5}

      # Second increment: 5 + 3 = 8 (should broadcast 8, not 3)
      ref2 = push(socket, "write", %{
        "op" => "increment",
        "path" => "stats.views",
        "value" => 3,
        "client_op_id" => "inc_2"
      })

      assert_reply ref2, :ok, %{store_seq: 2}
      assert_broadcast "event", %{store_seq: 2, path: "stats.views", value: 8}
    end

    test "add broadcasts materialized set, not member", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      ref = push(socket, "write", %{
        "op" => "add",
        "path" => "post.tags",
        "value" => "elixir",
        "client_op_id" => "add_1"
      })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, path: "post.tags", value: ["elixir"]}

      ref2 = push(socket, "write", %{
        "op" => "add",
        "path" => "post.tags",
        "value" => "rust",
        "client_op_id" => "add_2"
      })

      assert_reply ref2, :ok, %{store_seq: 2}
      # Should broadcast full set, not just the new member
      assert_broadcast "event", %{store_seq: 2, path: "post.tags", value: value}
      assert "elixir" in value
      assert "rust" in value
    end

    test "ack_seq updates last_acked_seq", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      ref = push(socket, "ack_seq", %{"seq" => 42})
      assert_reply ref, :ok
    end

    test "rejects merge with non-map value", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      ref =
        push(socket, "write", %{
          "op" => "merge",
          "path" => "settings",
          "value" => "not_a_map",
          "client_op_id" => "o1"
        })

      assert_reply ref, :error, %{reason: "merge_requires_map_value"}
    end
  end
end
