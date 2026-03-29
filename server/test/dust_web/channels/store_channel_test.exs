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

      # Should receive catch-up events
      assert_push "event", %{store_seq: 1, path: "a"}
      assert_push "event", %{store_seq: 2, path: "b"}
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
  end
end
