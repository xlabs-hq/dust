defmodule Dust.SingleFlightTest do
  use ExUnit.Case

  alias Dust.SyncEngine

  @store "sf/store"

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} =
      SyncEngine.start_link(store: @store, cache: {Dust.Cache.Memory, []})

    # Intercept {:send_write, store, op} so the test can play the server.
    Process.register(self(), Dust.Connection)
    SyncEngine.set_status(@store, :connected)
    _ = SyncEngine.status(@store)
    :ok
  end

  test "fast path returns :cached without acquiring a lease (presence mode)" do
    :ok = SyncEngine.seed_entry(@store, "k", Jason.encode!(%{"r" => 9}), "string")

    assert {:ok, %Dust.Flight{value: %{"r" => 9}, source: :cached, stale?: false}} =
             Dust.single_flight(@store, "k", fn _ -> {:publish, :unused} end)

    refute_receive {:send_write, @store, _}, 100
  end

  test "won path: computes, publishes fenced, releases, returns :computed" do
    task =
      Task.async(fn ->
        Dust.single_flight(@store, "k", fn _lease -> {:publish, %{"r" => 1}} end,
          lease_ttl: 30_000
        )
      end)

    # 1. acquire the lease
    assert_receive {:send_write, @store, %{op: :lease, path: "_dust:sf/k", client_op_id: lid}},
                   500

    SyncEngine.handle_write_accepted(@store, lid, %{store_seq: 1, token: 1, expires_at: 9_999})

    # 2. fenced publish of the JSON-encoded value to the result key
    assert_receive {:send_write, @store,
                    %{
                      op: :set,
                      path: "k",
                      value: value,
                      fence: %{key: "_dust:sf/k", token: 1},
                      client_op_id: pid
                    }},
                   500

    assert value == ~s({"r":1})
    SyncEngine.handle_write_accepted(@store, pid, %{store_seq: 2})

    # 3. release the lease
    assert_receive {:send_write, @store, %{op: :release, token: 1, client_op_id: rid}}, 500
    SyncEngine.handle_write_accepted(@store, rid, %{store_seq: 3})

    assert {:ok, %Dust.Flight{value: %{"r" => 1}, source: :computed, coordinated?: true}} =
             Task.await(task, 1_000)
  end

  test "abort releases the lease and surfaces the error (no publish)" do
    task =
      Task.async(fn ->
        Dust.single_flight(@store, "k", fn _ -> {:abort, :upstream_down} end, lease_ttl: 30_000)
      end)

    assert_receive {:send_write, @store, %{op: :lease, client_op_id: lid}}, 500
    SyncEngine.handle_write_accepted(@store, lid, %{store_seq: 1, token: 1, expires_at: 9_999})

    # Straight to release — no :set publish.
    assert_receive {:send_write, @store, %{op: :release, token: 1, client_op_id: rid}}, 500
    SyncEngine.handle_write_accepted(@store, rid, %{store_seq: 2})

    assert Task.await(task, 1_000) == {:error, :upstream_down}
  end

  test "freshness mode: stale value coordinates, loser awaits a fresh publish" do
    :ok = SyncEngine.seed_entry(@store, "k", Jason.encode!(%{"age" => 100}), "string")

    task =
      Task.async(fn ->
        Dust.single_flight(@store, "k", fn _ -> {:publish, %{"age" => 0}} end,
          fresh?: fn v -> v["age"] < 50 end
        )
      end)

    # 100 >= 50 -> stale -> coordinate. Pretend someone else holds it.
    assert_receive {:send_write, @store, %{op: :lease, client_op_id: lid}}, 500
    SyncEngine.handle_write_rejected(@store, lid, "held")

    # The winner (elsewhere) publishes a fresh value -> committed event wakes us.
    SyncEngine.handle_server_event(@store, %{
      "path" => "k",
      "op" => "set",
      "value" => Jason.encode!(%{"age" => 0}),
      "store_seq" => 5,
      "device_id" => "other",
      "client_op_id" => "remote-op"
    })

    assert {:ok, %Dust.Flight{value: %{"age" => 0}, source: :awaited}} = Task.await(task, 1_000)
  end

  test "loser re-elects and is promoted when the holder goes away" do
    # Small lease_ttl so the time-based re-election poll (steal of a crashed
    # holder's expired lease) fires quickly and deterministically. fun is
    # instant, so the heartbeat (ttl/3) never fires before stop.
    task =
      Task.async(fn ->
        Dust.single_flight(@store, "k", fn _ -> {:publish, %{"r" => 2}} end, lease_ttl: 300)
      end)

    # 1. first acquire loses — someone else holds it
    assert_receive {:send_write, @store, %{op: :lease, client_op_id: l1}}, 500
    SyncEngine.handle_write_rejected(@store, l1, "held")

    # 2. a committed release on the lock key may wake us early; otherwise the
    #    ~lease_ttl poll re-election guarantees a re-attempt either way.
    SyncEngine.handle_server_event(@store, %{
      "path" => "_dust:sf/k",
      "op" => "release",
      "value" => nil,
      "store_seq" => 4,
      "device_id" => "other",
      "client_op_id" => "other-release"
    })

    # 3. re-acquire succeeds → promoted to winner → publish → release
    assert_receive {:send_write, @store, %{op: :lease, client_op_id: l2}}, 1_000
    SyncEngine.handle_write_accepted(@store, l2, %{store_seq: 5, token: 5, expires_at: 9_999})

    assert_receive {:send_write, @store, %{op: :set, path: "k", client_op_id: p1}}, 500
    SyncEngine.handle_write_accepted(@store, p1, %{store_seq: 6})

    assert_receive {:send_write, @store, %{op: :release, token: 5, client_op_id: r1}}, 500
    SyncEngine.handle_write_accepted(@store, r1, %{store_seq: 7})

    assert {:ok, %Dust.Flight{value: %{"r" => 2}, source: :computed}} = Task.await(task, 2_000)
  end

  test "run_local degrade: runs uncoordinated when Dust is unavailable" do
    SyncEngine.set_status(@store, :disconnected)
    _ = SyncEngine.status(@store)

    # lease fails fast with :unavailable -> :run_local runs fun with a nil lease.
    assert {:ok, %Dust.Flight{value: %{"r" => 7}, source: :computed, coordinated?: false}} =
             Dust.single_flight(
               @store,
               "k",
               fn lease ->
                 assert lease == nil
                 {:publish, %{"r" => 7}}
               end,
               on_unavailable: :run_local
             )
  end

  test "run_local does not degrade when lease is rejected for missing write scope" do
    test_pid = self()

    task =
      Task.async(fn ->
        Dust.single_flight(
          @store,
          "k",
          fn _lease ->
            send(test_pid, :ran)
            {:publish, %{"r" => 7}}
          end,
          on_unavailable: :run_local
        )
      end)

    assert_receive {:send_write, @store, %{op: :lease, client_op_id: id}}, 500

    SyncEngine.handle_write_rejected(@store, id, %{
      "reason" => "missing_scope",
      "scope" => "entries:write"
    })

    assert {:error, {:missing_scope, "entries:write", "Token is missing entries:write scope"}} =
             Task.await(task, 500)

    refute_receive :ran, 100
  end
end
