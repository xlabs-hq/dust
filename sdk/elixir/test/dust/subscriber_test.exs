defmodule Dust.SubscriberTest do
  use ExUnit.Case

  defmodule TestSubscriber do
    use Dust.Subscriber,
      store: "test/subscriber",
      pattern: "posts.*"

    @impl true
    def handle_event(event) do
      Agent.update(:subscriber_test_collector, fn events -> [event | events] end)
      :ok
    end
  end

  defmodule CustomQueueSubscriber do
    use Dust.Subscriber,
      store: "test/subscriber",
      pattern: "logs.*",
      max_queue_size: 50

    @impl true
    def handle_event(_event), do: :ok
  end

  defmodule SubscriberDust do
    use Dust, otp_app: :dust_subscriber_test
  end

  setup do
    {:ok, collector} = Agent.start_link(fn -> [] end, name: :subscriber_test_collector)

    Application.put_env(:dust_subscriber_test, SubscriberDust,
      stores: ["test/subscriber"],
      cache: {Dust.Cache.Memory, []},
      testing: :manual,
      subscribers: [TestSubscriber]
    )

    start_supervised!(SubscriberDust)

    on_exit(fn ->
      if Process.alive?(collector), do: Agent.stop(collector)
    end)

    :ok
  end

  test "subscriber module declares store and pattern" do
    assert TestSubscriber.__dust_store__() == "test/subscriber"
    assert TestSubscriber.__dust_pattern__() == "posts.*"
  end

  test "subscriber module declares max_queue_size with default" do
    assert TestSubscriber.__dust_max_queue_size__() == 1000
  end

  test "subscriber module declares custom max_queue_size" do
    assert CustomQueueSubscriber.__dust_max_queue_size__() == 50
  end

  test "subscriber is called when matching server event arrives" do
    Dust.SyncEngine.handle_server_event("test/subscriber", %{
      "path" => "posts.hello",
      "op" => "set",
      "value" => %{"title" => "Hello"},
      "store_seq" => 1,
      "device_id" => "remote_device",
      "client_op_id" => "remote_op_1"
    })

    # Give the async callback worker time to process
    Process.sleep(100)

    events = Agent.get(:subscriber_test_collector, & &1)
    assert length(events) == 1
    [event] = events
    assert event.path == "posts.hello"
    assert event.op == :set
    assert event.value == %{"title" => "Hello"}
    assert event.source == :server
    assert event.committed == true
  end

  test "subscriber is NOT called for non-matching paths" do
    Dust.SyncEngine.handle_server_event("test/subscriber", %{
      "path" => "config.x",
      "op" => "set",
      "value" => "val",
      "store_seq" => 2,
      "device_id" => "remote_device",
      "client_op_id" => "remote_op_2"
    })

    Process.sleep(100)

    events = Agent.get(:subscriber_test_collector, & &1)
    assert events == []
  end

  test "subscriber handles multiple matching events" do
    for i <- 1..3 do
      Dust.SyncEngine.handle_server_event("test/subscriber", %{
        "path" => "posts.post_#{i}",
        "op" => "set",
        "value" => "content_#{i}",
        "store_seq" => i,
        "device_id" => "remote_device",
        "client_op_id" => "remote_op_#{i}"
      })
    end

    Process.sleep(200)

    events = Agent.get(:subscriber_test_collector, & &1)
    assert length(events) == 3
    paths = Enum.map(events, & &1.path) |> Enum.sort()
    assert paths == ["posts.post_1", "posts.post_2", "posts.post_3"]
  end

  test "subscriber receives delete events" do
    Dust.SyncEngine.handle_server_event("test/subscriber", %{
      "path" => "posts.removed",
      "op" => "delete",
      "value" => nil,
      "store_seq" => 10,
      "device_id" => "remote_device",
      "client_op_id" => "remote_op_del"
    })

    Process.sleep(100)

    events = Agent.get(:subscriber_test_collector, & &1)
    assert length(events) == 1
    [event] = events
    assert event.op == :delete
    assert event.path == "posts.removed"
  end

  test "__dust_register__ can be called manually" do
    # Verify it returns a ref (the callback registration reference)
    ref = TestSubscriber.__dust_register__()
    assert is_reference(ref)
  end
end
