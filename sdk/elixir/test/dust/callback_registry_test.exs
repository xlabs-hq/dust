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

    {worker_pid, _ref, _max, _resync} = hd(subscriptions)
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

  test "unregister removes callback and stops worker", %{table: table} do
    ref = CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)

    [{pid, _, _, _}] = CallbackRegistry.match(table, "james/blog", "posts.hello")
    assert Process.alive?(pid)

    CallbackRegistry.unregister(table, ref)
    assert CallbackRegistry.match(table, "james/blog", "posts.hello") == []
    # Worker should be stopped
    Process.sleep(10)
    refute Process.alive?(pid)
  end
end
