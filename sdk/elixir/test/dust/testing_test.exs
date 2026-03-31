defmodule Dust.TestingTest do
  use ExUnit.Case

  defmodule TestDust do
    use Dust, otp_app: :dust_testing_test
  end

  setup do
    Application.put_env(:dust_testing_test, TestDust,
      stores: ["test/store"],
      testing: :manual
    )

    start_supervised!(TestDust)
    :ok
  end

  test "seed populates cache for get" do
    Dust.Testing.seed("test/store", %{
      "posts.hello" => %{"title" => "Hello"},
      "posts.goodbye" => %{"title" => "Goodbye"}
    })

    assert {:ok, %{"title" => "Hello"}} = TestDust.get("test/store", "posts.hello")
    assert {:ok, %{"title" => "Goodbye"}} = TestDust.get("test/store", "posts.goodbye")
  end

  test "seed populates cache for enum" do
    Dust.Testing.seed("test/store", %{
      "posts.a" => "1",
      "posts.b" => "2",
      "config.x" => "3"
    })

    results = TestDust.enum("test/store", "posts.*")
    assert length(results) == 2
  end

  test "emit triggers subscriber callbacks synchronously" do
    test_pid = self()

    TestDust.on("test/store", "posts.*", fn event ->
      send(test_pid, {:event_received, event})
    end)

    Dust.Testing.emit("test/store", "posts.hello",
      op: :set,
      value: %{"title" => "New"}
    )

    assert_receive {:event_received, %{path: "posts.hello", value: %{"title" => "New"}}}, 100
  end

  test "emit updates cache state" do
    Dust.Testing.emit("test/store", "key",
      op: :set,
      value: "from_server"
    )

    assert {:ok, "from_server"} = TestDust.get("test/store", "key")
  end

  test "set_status controls status response" do
    Dust.Testing.set_status("test/store", :connected, store_seq: 42)

    status = TestDust.status("test/store")
    assert status.connection == :connected
    assert status.last_store_seq == 42
  end

  test "build_event creates a properly shaped event map" do
    event = Dust.Testing.build_event("test/store", "posts.hello",
      op: :set,
      value: %{"title" => "Hello"},
      store_seq: 5
    )

    assert event.store == "test/store"
    assert event.path == "posts.hello"
    assert event.op == :set
    assert event.value == %{"title" => "Hello"}
    assert event.store_seq == 5
    assert event.committed == true
    assert event.source == :server
    assert event.device_id == "test"
    assert event.client_op_id == "test"
  end
end
