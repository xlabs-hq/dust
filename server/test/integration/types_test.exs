defmodule Dust.Integration.TypesTest do
  use Dust.DataCase, async: false
  import Phoenix.ChannelTest
  import Dust.IntegrationHelpers

  describe "counter via channel" do
    test "increment op works through channel" do
      %{token: token, store: store} = create_test_store("ctr", "ctr_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref =
        push(socket, "write", %{
          "op" => "increment",
          "path" => "stats.views",
          "value" => 3,
          "client_op_id" => "o1"
        })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, op: :increment, path: "stats.views"}

      entry = Dust.Sync.get_entry(store.id, "stats.views")
      assert entry.value == 3
    end

    test "multiple increments accumulate through channel" do
      %{token: token, store: store} = create_test_store("ctr2", "ctr2_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref1 =
        push(socket, "write", %{
          "op" => "increment",
          "path" => "stats.views",
          "value" => 3,
          "client_op_id" => "o1"
        })

      assert_reply ref1, :ok, %{store_seq: 1}

      ref2 =
        push(socket, "write", %{
          "op" => "increment",
          "path" => "stats.views",
          "value" => 5,
          "client_op_id" => "o2"
        })

      assert_reply ref2, :ok, %{store_seq: 2}

      entry = Dust.Sync.get_entry(store.id, "stats.views")
      assert entry.value == 8
    end

    test "rejects increment with non-number value" do
      %{token: token, store: store} = create_test_store("ctr3", "ctr3_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref =
        push(socket, "write", %{
          "op" => "increment",
          "path" => "stats.views",
          "value" => "not_a_number",
          "client_op_id" => "o1"
        })

      assert_reply ref, :error, %{reason: "increment_requires_number_value"}
    end
  end

  describe "decimal and datetime via catch-up" do
    test "catch-up delivers Decimal values unwrapped" do
      %{token: token, store: store} = create_test_store("dec", "dec_store")

      # Write a Decimal directly via Sync (simulates server-side write)
      Dust.Sync.write(store.id, %{
        op: :set,
        path: "product.price",
        value: Decimal.new("29.99"),
        device_id: "server",
        client_op_id: "o1"
      })

      # Now connect a client at seq 0 — should get catch-up with the typed value
      {_socket, _reply} = connect_client(token, store, "dev_1", 0)

      assert_push "event", event
      assert event.path == "product.price"
      assert %Decimal{} = event.value
      assert Decimal.equal?(event.value, Decimal.new("29.99"))
    end

    test "catch-up delivers DateTime values unwrapped" do
      %{token: token, store: store} = create_test_store("dtc", "dtc_store")

      dt = ~U[2026-03-31 12:00:00Z]

      Dust.Sync.write(store.id, %{
        op: :set,
        path: "event.starts_at",
        value: dt,
        device_id: "server",
        client_op_id: "o1"
      })

      {_socket, _reply} = connect_client(token, store, "dev_1", 0)

      assert_push "event", event
      assert event.path == "event.starts_at"
      assert %DateTime{} = event.value
      assert DateTime.compare(event.value, dt) == :eq
    end
  end

  describe "set via channel" do
    test "add op works through channel" do
      %{token: token, store: store} = create_test_store("setc", "setc_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref =
        push(socket, "write", %{
          "op" => "add",
          "path" => "post.tags",
          "value" => "elixir",
          "client_op_id" => "o1"
        })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, op: :add, path: "post.tags"}

      entry = Dust.Sync.get_entry(store.id, "post.tags")
      assert entry.value == ["elixir"]
    end

    test "remove op works through channel" do
      %{token: token, store: store} = create_test_store("setr", "setr_store")
      {socket, _} = connect_client(token, store, "dev_1")

      # Add first
      ref1 =
        push(socket, "write", %{
          "op" => "add",
          "path" => "post.tags",
          "value" => "elixir",
          "client_op_id" => "o1"
        })

      assert_reply ref1, :ok, _

      ref2 =
        push(socket, "write", %{
          "op" => "add",
          "path" => "post.tags",
          "value" => "rust",
          "client_op_id" => "o2"
        })

      assert_reply ref2, :ok, _

      # Remove one
      ref3 =
        push(socket, "write", %{
          "op" => "remove",
          "path" => "post.tags",
          "value" => "elixir",
          "client_op_id" => "o3"
        })

      assert_reply ref3, :ok, %{store_seq: 3}

      entry = Dust.Sync.get_entry(store.id, "post.tags")
      assert entry.value == ["rust"]
    end

    test "add with nil value is rejected" do
      %{token: token, store: store} = create_test_store("setv", "setv_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref =
        push(socket, "write", %{
          "op" => "add",
          "path" => "post.tags",
          "value" => nil,
          "client_op_id" => "o1"
        })

      assert_reply ref, :error, %{reason: "add_requires_value"}
    end

    test "remove with nil value is rejected" do
      %{token: token, store: store} = create_test_store("setrv", "setrv_store")
      {socket, _} = connect_client(token, store, "dev_1")

      ref =
        push(socket, "write", %{
          "op" => "remove",
          "path" => "post.tags",
          "value" => nil,
          "client_op_id" => "o1"
        })

      assert_reply ref, :error, %{reason: "remove_requires_value"}
    end
  end
end
