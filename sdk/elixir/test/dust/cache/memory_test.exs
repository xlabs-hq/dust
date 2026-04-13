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

  test "browse with order: :desc returns entries in reverse lex order", %{cache: cache} do
    for k <- ~w(a b c d), do: :ok = Memory.write(cache, "s", k, k, "string", 1)

    {page, _} = Memory.browse(cache, "s", limit: 10, order: :desc)
    assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(d c b a)
  end

  test "browse with order: :desc and cursor drops entries >= cursor", %{cache: cache} do
    for k <- ~w(a b c d), do: :ok = Memory.write(cache, "s", k, k, "string", 1)

    {page, _} = Memory.browse(cache, "s", limit: 10, order: :desc, cursor: "c")
    # desc + cursor "c" means next items are strictly less than "c"
    assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(b a)
  end

  test "browse with select: :keys returns only path strings in order", %{cache: cache} do
    for k <- ~w(a b c), do: :ok = Memory.write(cache, "s", k, k, "string", 1)

    {items, _} = Memory.browse(cache, "s", select: :keys, limit: 10)
    assert items == ~w(a b c)
    assert Enum.all?(items, &is_binary/1)
  end

  test "browse with select: :entries (default) returns 4-tuples", %{cache: cache} do
    :ok = Memory.write(cache, "s", "a", "va", "string", 1)
    :ok = Memory.write(cache, "s", "b", "vb", "string", 2)

    {items, _} = Memory.browse(cache, "s", limit: 10)
    assert items == [{"a", "va", "string", 1}, {"b", "vb", "string", 2}]
  end
end
