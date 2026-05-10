defmodule Dust.CallbackRegistryTest do
  use ExUnit.Case, async: true

  alias Dust.CallbackRegistry

  setup do
    table = CallbackRegistry.new()
    %{table: table}
  end

  test "register and match", %{table: table} do
    test_pid = self()
    callback = fn event -> send(test_pid, {:callback, event}) end

    ref = CallbackRegistry.register(table, "james/blog", "posts.*", callback)
    assert is_reference(ref)

    subscriptions = CallbackRegistry.match(table, "james/blog", "posts.hello")
    assert length(subscriptions) == 1

    {worker_pid, _ref, _max, _resync, _mode} = hd(subscriptions)
    Dust.CallbackWorker.dispatch(worker_pid, %{path: "posts.hello"})
    # Worker processes events asynchronously, give it a moment
    assert_receive {:callback, %{path: "posts.hello"}}, 500
  end

  test "does not match wrong store", %{table: table} do
    CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    assert CallbackRegistry.match(table, "other/store", "posts.hello") == []
  end

  test "does not match wrong pattern", %{table: table} do
    CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    assert CallbackRegistry.match(table, "james/blog", "config.x") == []
  end

  test "lookup returns {worker_pid, max_queue_size, on_resync, mode} for a registered subscription",
       %{table: table} do
    on_resync = fn _ -> :ok end

    ref =
      CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end,
        max_queue_size: 42,
        on_resync: on_resync
      )

    assert {worker_pid, 42, ^on_resync, :all} = CallbackRegistry.lookup(table, ref)
    assert is_pid(worker_pid)
    assert Process.alive?(worker_pid)
  end

  test "register stores explicit :mode opt", %{table: table} do
    ref =
      CallbackRegistry.register(table, "s", "**", fn _ -> :ok end, mode: :committed)

    assert {_pid, _max, _resync, :committed} = CallbackRegistry.lookup(table, ref)
  end

  test "register raises on invalid :mode", %{table: table} do
    assert_raise ArgumentError, ~r/invalid :mode/, fn ->
      CallbackRegistry.register(table, "s", "**", fn _ -> :ok end, mode: :bogus)
    end
  end

  test "lookup returns nil for an unknown ref", %{table: table} do
    assert CallbackRegistry.lookup(table, make_ref()) == nil
  end

  test "unregister removes callback and stops worker", %{table: table} do
    ref = CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)

    [{pid, _, _, _, _}] = CallbackRegistry.match(table, "james/blog", "posts.hello")
    assert Process.alive?(pid)

    CallbackRegistry.unregister(table, ref)
    assert CallbackRegistry.match(table, "james/blog", "posts.hello") == []
    # Worker should be stopped
    Process.sleep(10)
    refute Process.alive?(pid)
  end
end
