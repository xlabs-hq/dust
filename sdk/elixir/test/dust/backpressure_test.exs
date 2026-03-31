defmodule Dust.BackpressureTest do
  use ExUnit.Case

  alias Dust.SyncEngine

  setup do
    store = "bp_test/store_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} =
      SyncEngine.start_link(
        store: store,
        cache: {Dust.Cache.Memory, []}
      )

    %{store: store}
  end

  test "subscription is dropped when worker mailbox exceeds max_queue_size", %{store: store} do
    test_pid = self()

    # A callback that blocks indefinitely until told to continue.
    # This simulates a slow consumer — events pile up in the worker mailbox.
    slow_callback = fn _event ->
      receive do
        :continue -> :ok
      end
    end

    on_resync = fn info ->
      send(test_pid, {:resync_required, info})
    end

    ref =
      SyncEngine.on(store, "items.*", slow_callback,
        max_queue_size: 5,
        on_resync: on_resync
      )

    assert is_reference(ref)

    # Flood the SyncEngine with server events. Each one dispatches to the worker.
    # The worker is blocked on the first event, so events pile up in its mailbox.
    for i <- 1..10 do
      SyncEngine.handle_server_event(store, %{
        "op" => "set",
        "path" => "items.item_#{i}",
        "value" => "val_#{i}",
        "store_seq" => i,
        "client_op_id" => nil,
        "device_id" => "dev1"
      })
    end

    # The SyncEngine processes casts sequentially — give it time to process all events
    # and detect the backpressure threshold.
    assert_receive {:resync_required, %{error: :resync_required, ref: ^ref}}, 2_000

    # After resync_required fires, the subscription should be unregistered.
    # Sending more events should NOT trigger additional resync callbacks.
    for i <- 11..15 do
      SyncEngine.handle_server_event(store, %{
        "op" => "set",
        "path" => "items.item_#{i}",
        "value" => "val_#{i}",
        "store_seq" => i,
        "client_op_id" => nil,
        "device_id" => "dev1"
      })
    end

    # Give time for any spurious messages
    Process.sleep(100)
    refute_receive {:resync_required, _}
  end

  test "fast callback does not trigger resync_required", %{store: store} do
    test_pid = self()
    events_received = :counters.new(1, [:atomics])

    fast_callback = fn _event ->
      :counters.add(events_received, 1, 1)
      send(test_pid, :event_processed)
    end

    on_resync = fn info ->
      send(test_pid, {:resync_required, info})
    end

    SyncEngine.on(store, "items.*", fast_callback,
      max_queue_size: 5,
      on_resync: on_resync
    )

    # Send a few events — the fast callback processes them quickly
    for i <- 1..3 do
      SyncEngine.handle_server_event(store, %{
        "op" => "set",
        "path" => "items.item_#{i}",
        "value" => "val_#{i}",
        "store_seq" => i,
        "client_op_id" => nil,
        "device_id" => "dev1"
      })
    end

    # Wait for all events to be processed
    for _ <- 1..3 do
      assert_receive :event_processed, 1_000
    end

    # No resync should have fired
    refute_receive {:resync_required, _}
    assert :counters.get(events_received, 1) == 3
  end

  test "one slow subscriber does not stall other subscriptions", %{store: store} do
    test_pid = self()

    # Slow subscriber blocks
    slow_callback = fn _event ->
      receive do
        :continue -> :ok
      end
    end

    slow_resync = fn info ->
      send(test_pid, {:slow_resync, info})
    end

    # Fast subscriber processes immediately
    fast_callback = fn event ->
      send(test_pid, {:fast_event, event})
    end

    fast_resync = fn info ->
      send(test_pid, {:fast_resync, info})
    end

    SyncEngine.on(store, "items.*", slow_callback,
      max_queue_size: 3,
      on_resync: slow_resync
    )

    SyncEngine.on(store, "items.*", fast_callback,
      max_queue_size: 1000,
      on_resync: fast_resync
    )

    # Send events
    for i <- 1..8 do
      SyncEngine.handle_server_event(store, %{
        "op" => "set",
        "path" => "items.item_#{i}",
        "value" => "val_#{i}",
        "store_seq" => i,
        "client_op_id" => nil,
        "device_id" => "dev1"
      })
    end

    # The slow subscriber should get dropped
    assert_receive {:slow_resync, %{error: :resync_required}}, 2_000

    # The fast subscriber should receive all events (it never exceeds its queue limit)
    fast_events =
      for _ <- 1..8 do
        assert_receive {:fast_event, %{path: path}}, 1_000
        path
      end

    assert length(fast_events) == 8

    # Fast subscriber should NOT have been dropped
    refute_receive {:fast_resync, _}
  end

  test "local writes also respect backpressure", %{store: store} do
    test_pid = self()

    slow_callback = fn _event ->
      receive do
        :continue -> :ok
      end
    end

    on_resync = fn info ->
      send(test_pid, {:resync_required, info})
    end

    ref =
      SyncEngine.on(store, "items.*", slow_callback,
        max_queue_size: 5,
        on_resync: on_resync
      )

    # Flood with local writes instead of server events
    for i <- 1..10 do
      SyncEngine.put(store, "items.item_#{i}", "val_#{i}")
    end

    assert_receive {:resync_required, %{error: :resync_required, ref: ^ref}}, 2_000
  end
end
