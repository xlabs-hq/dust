defmodule DustWeb.StoreChannelTest do
  use Dust.DataCase, async: false
  use Oban.Testing, repo: Dust.Repo
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
      assert reply.capver == DustProtocol.current_capver()
      assert reply.capver_min == DustProtocol.min_capver()

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

    test "put_file enforces file storage billing check", %{joined_socket: socket} do
      # Small file should succeed on free plan (100MB limit)
      small_content = "hello"

      ref =
        push(socket, "put_file", %{
          "path" => "docs.small",
          "content" => Base.encode64(small_content),
          "filename" => "small.txt",
          "content_type" => "text/plain",
          "client_op_id" => "file_billing"
        })

      # The billing check runs and passes for small files
      assert_reply ref, :ok, _
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
      ref =
        push(socket, "write", %{
          "op" => "increment",
          "path" => "stats.views",
          "value" => 5,
          "client_op_id" => "inc_1"
        })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, path: "stats.views", value: 5}

      # Second increment: 5 + 3 = 8 (should broadcast 8, not 3)
      ref2 =
        push(socket, "write", %{
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

      ref =
        push(socket, "write", %{
          "op" => "add",
          "path" => "post.tags",
          "value" => "elixir",
          "client_op_id" => "add_1"
        })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, path: "post.tags", value: ["elixir"]}

      ref2 =
        push(socket, "write", %{
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
  end

  describe "catch-up materialized values" do
    test "catch-up sends correct materialized values for sequential increments", %{
      socket: socket,
      store: store
    } do
      Sync.write(store.id, %{
        op: :increment,
        path: "counter",
        value: 5,
        device_id: "d",
        client_op_id: "i1"
      })

      Sync.write(store.id, %{
        op: :increment,
        path: "counter",
        value: 3,
        device_id: "d",
        client_op_id: "i2"
      })

      {:ok, _, _socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      # First increment should send 5 (not 8)
      assert_push "event", %{store_seq: 1, path: "counter", value: 5}
      # Second increment should send 8
      assert_push "event", %{store_seq: 2, path: "counter", value: 8}
    end

    test "catch-up sends correct materialized values for add ops", %{
      socket: socket,
      store: store
    } do
      Sync.write(store.id, %{
        op: :add,
        path: "tags",
        value: "elixir",
        device_id: "d",
        client_op_id: "a1"
      })

      Sync.write(store.id, %{
        op: :add,
        path: "tags",
        value: "rust",
        device_id: "d",
        client_op_id: "a2"
      })

      {:ok, _, _socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      # First add should send ["elixir"] (not ["elixir", "rust"])
      assert_push "event", %{store_seq: 1, path: "tags", value: ["elixir"]}
      # Second add should send ["elixir", "rust"] (order may vary)
      assert_push "event", %{store_seq: 2, path: "tags", value: value}
      assert "elixir" in value
      assert "rust" in value
      assert length(value) == 2
    end
  end

  describe "billing key count checks" do
    test "set of map correctly counts only new leaf entries", %{socket: socket, store: store} do
      # Fill store to 998 entries
      for i <- 1..998 do
        Sync.write(store.id, %{
          op: :set,
          path: "k#{i}",
          value: "v",
          device_id: "d",
          client_op_id: "fill_#{i}"
        })
      end

      # Create data.x → 999 entries total
      Sync.write(store.id, %{
        op: :set,
        path: "data.x",
        value: "existing",
        device_id: "d",
        client_op_id: "setup"
      })

      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 999
        })

      assert_push "catch_up_complete", _

      # Set data = {x: updated, y: new} — 2 leaves, but only 1 is new (data.y)
      # Bug: counts 2 new → 999 + 2 = 1001 → rejected
      # Fix: counts 1 new → 999 + 1 = 1000 → allowed
      ref =
        push(socket, "write", %{
          "op" => "set",
          "path" => "data",
          "value" => %{"x" => "updated", "y" => "new"},
          "client_op_id" => "map_set"
        })

      assert_reply ref, :ok, _
    end

    test "merge counts keys using full path prefix", %{socket: socket, store: store} do
      # Fill store to 998 entries
      for i <- 1..998 do
        Sync.write(store.id, %{
          op: :set,
          path: "k#{i}",
          value: "v",
          device_id: "d",
          client_op_id: "fill_#{i}"
        })
      end

      # Create settings.theme → 999 entries total
      Sync.write(store.id, %{
        op: :set,
        path: "settings.theme",
        value: "dark",
        device_id: "d",
        client_op_id: "setup"
      })

      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 999
        })

      assert_push "catch_up_complete", _

      # Merge {theme: light, lang: en} into "settings"
      # Should check "settings.theme" (exists) and "settings.lang" (new)
      # Bug: checks just "theme" (not found → counts as new) and "lang" (new) = 2 new
      # Fix: checks "settings.theme" (found → not new) and "settings.lang" (new) = 1 new
      # 999 + 1 = 1000 → allowed
      ref =
        push(socket, "write", %{
          "op" => "merge",
          "path" => "settings",
          "value" => %{"theme" => "light", "lang" => "en"},
          "client_op_id" => "merge_op"
        })

      assert_reply ref, :ok, _

      assert Sync.get_entry(store.id, "settings.theme").value == "light"
      assert Sync.get_entry(store.id, "settings.lang").value == "en"
    end
  end

  describe "status" do
    test "returns store status info", %{socket: socket, store: store} do
      Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})

      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      # Drain catch-up events
      assert_push "event", _
      assert_push "event", _
      assert_push "catch_up_complete", _

      ref = push(socket, "status", %{})
      assert_reply ref, :ok, status

      assert status.current_seq == 2
      assert status.entry_count == 2
      assert is_integer(status.db_size_bytes)
      assert status.db_size_bytes > 0
      assert is_list(status.recent_ops)
      assert length(status.recent_ops) == 2
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

  describe "writes after archive" do
    test "write is rejected after store is archived", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      # Drain catch-up
      assert_push "catch_up_complete", _

      # Archive the store while client is connected
      import Ecto.Query

      from(s in Dust.Stores.Store, where: s.id == ^store.id)
      |> Dust.Repo.update_all(set: [status: :archived])

      # Attempt to write — should be rejected
      ref =
        push(socket, "write", %{
          "op" => "set",
          "path" => "sneaky",
          "value" => "after-expiry",
          "client_op_id" => "late_1"
        })

      assert_reply ref, :error, %{reason: "store_archived"}
    end

    test "put_file is rejected after store is archived", %{socket: socket, store: store} do
      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      # Drain catch-up
      assert_push "catch_up_complete", _

      # Archive the store
      import Ecto.Query

      from(s in Dust.Stores.Store, where: s.id == ^store.id)
      |> Dust.Repo.update_all(set: [status: :archived])

      ref =
        push(socket, "put_file", %{
          "path" => "docs.sneaky",
          "content" => Base.encode64("payload"),
          "client_op_id" => "late_file"
        })

      assert_reply ref, :error, %{reason: "store_archived"}
    end
  end

  describe "webhook delivery" do
    test "write enqueues webhook delivery jobs", %{socket: socket, store: store} do
      {:ok, _webhook} = Dust.Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

      {:ok, _, socket} =
        subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{
          "last_store_seq" => 0
        })

      # Drain catch-up
      assert_push "catch_up_complete", _

      ref =
        push(socket, "write", %{
          "op" => "set",
          "path" => "a",
          "value" => "1",
          "client_op_id" => "o1"
        })

      assert_reply ref, :ok, _

      # Verify an Oban job was enqueued
      jobs = all_enqueued(worker: Dust.Webhooks.DeliveryWorker)
      assert length(jobs) == 1
    end
  end
end
