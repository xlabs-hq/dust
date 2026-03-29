defmodule Dust.ConnectionTest do
  use Slipstream.SocketTest

  alias Dust.{Connection, SyncEngine}

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _engine} =
      start_supervised(
        {SyncEngine, store: "test/mystore", cache: {Dust.Cache.Memory, []}},
        id: :engine1
      )

    {:ok, conn} =
      start_supervised(
        {Connection,
         url: "ws://localhost:7000/ws/sync",
         token: "dust_tok_test",
         device_id: "dev_test123",
         stores: ["test/mystore"],
         test_mode?: true,
         name: Dust.Connection}
      )

    %{conn: conn}
  end

  test "connects and joins store topic on connect", %{conn: conn} do
    connect_and_assert_join conn, "store:test/mystore", %{"last_store_seq" => 0}, {:ok, %{"store_seq" => 0}}
  end

  test "sets SyncEngine status to :connected after join", %{conn: conn} do
    connect_and_assert_join conn, "store:test/mystore", %{"last_store_seq" => 0}, {:ok, %{"store_seq" => 5}}

    # Give the cast time to process
    Process.sleep(50)

    status = SyncEngine.status("test/mystore")
    assert status.connection == :connected
  end

  test "forwards server events to SyncEngine", %{conn: conn} do
    # Set up a callback to capture the event
    test_pid = self()
    SyncEngine.on("test/mystore", "posts.*", fn event -> send(test_pid, {:event, event}) end)

    connect_and_assert_join conn, "store:test/mystore", %{"last_store_seq" => 0}, {:ok, %{"store_seq" => 0}}

    # Server pushes an event
    push(conn, "store:test/mystore", "event", %{
      "store_seq" => 1,
      "op" => "set",
      "path" => "posts.hello",
      "value" => %{"title" => "Hello World"},
      "device_id" => "dev_other",
      "client_op_id" => "op_remote123"
    })

    assert_receive {:event, %{path: "posts.hello", op: :set, source: :server}}, 1000
  end

  test "sends write to the server when SyncEngine writes", %{conn: conn} do
    connect_and_assert_join conn, "store:test/mystore", %{"last_store_seq" => 0}, {:ok, %{"store_seq" => 0}}

    # Trigger a write through SyncEngine
    :ok = SyncEngine.put("test/mystore", "posts.new", "content")

    # The Connection should push a "write" message
    assert_push "store:test/mystore", "write", %{
      "op" => "set",
      "path" => "posts.new",
      "value" => "content"
    }
  end

  test "sets SyncEngine status to :reconnecting on disconnect", %{conn: conn} do
    connect_and_assert_join conn, "store:test/mystore", %{"last_store_seq" => 0}, {:ok, %{"store_seq" => 0}}
    Process.sleep(50)

    assert SyncEngine.status("test/mystore").connection == :connected

    disconnect(conn, :heartbeat_timeout)
    Process.sleep(50)

    assert SyncEngine.status("test/mystore").connection == :reconnecting
  end
end
