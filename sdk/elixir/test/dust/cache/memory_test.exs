defmodule Dust.Cache.MemoryTest do
  use ExUnit.Case, async: true

  alias Dust.Cache.Memory

  setup do
    {:ok, pid} = Memory.start_link([])
    %{cache: pid}
  end

  test "write and read", %{cache: cache} do
    :ok = Memory.write(cache, "store", "posts.hello", %{"title" => "Hello"}, "map", 1)
    assert {:ok, %{"title" => "Hello"}} = Memory.read(cache, "store", "posts.hello")
  end

  test "read returns :miss for unknown path", %{cache: cache} do
    assert :miss = Memory.read(cache, "store", "nope")
  end

  test "delete removes entry", %{cache: cache} do
    Memory.write(cache, "store", "x", "v", "string", 1)
    :ok = Memory.delete(cache, "store", "x")
    assert :miss = Memory.read(cache, "store", "x")
  end

  test "last_seq returns 0 initially", %{cache: cache} do
    assert Memory.last_seq(cache, "store") == 0
  end

  test "last_seq tracks highest seq", %{cache: cache} do
    Memory.write(cache, "store", "a", "1", "string", 5)
    Memory.write(cache, "store", "b", "2", "string", 3)
    assert Memory.last_seq(cache, "store") == 5
  end

  test "read_all with glob pattern", %{cache: cache} do
    Memory.write(cache, "store", "posts.a", "1", "string", 1)
    Memory.write(cache, "store", "posts.b", "2", "string", 2)
    Memory.write(cache, "store", "config.x", "3", "string", 3)

    results = Memory.read_all(cache, "store", "posts.*")
    assert length(results) == 2
    paths = Enum.map(results, &elem(&1, 0))
    assert "posts.a" in paths
    assert "posts.b" in paths
  end

  test "read_entry/3 returns {value, type, seq} for present keys", %{cache: cache} do
    :ok = Memory.write(cache, "s1", "a.b", "hello", "string", 7)
    assert Memory.read_entry(cache, "s1", "a.b") == {:ok, {"hello", "string", 7}}
  end

  test "read_entry/3 returns :miss for absent keys", %{cache: cache} do
    assert Memory.read_entry(cache, "s1", "nope") == :miss
  end
end
