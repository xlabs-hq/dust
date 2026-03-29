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

    callbacks = CallbackRegistry.match(table, "james/blog", "posts.hello")
    assert length(callbacks) == 1

    hd(callbacks).(%{path: "posts.hello"})
    assert_receive {:callback, %{path: "posts.hello"}}
  end

  test "does not match wrong store", %{table: table} do
    CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    assert CallbackRegistry.match(table, "other/store", "posts.hello") == []
  end

  test "does not match wrong pattern", %{table: table} do
    CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    assert CallbackRegistry.match(table, "james/blog", "config.x") == []
  end

  test "unregister removes callback", %{table: table} do
    ref = CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    CallbackRegistry.unregister(table, ref)
    assert CallbackRegistry.match(table, "james/blog", "posts.hello") == []
  end
end
