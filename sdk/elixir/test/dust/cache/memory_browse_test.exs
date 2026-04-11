defmodule Dust.Cache.MemoryBrowseTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, pid} = Dust.Cache.Memory.start_link([])
    store = "test/store"

    # Seed 10 entries
    for i <- 1..10 do
      path = "items.item_#{String.pad_leading(to_string(i), 2, "0")}"
      Dust.Cache.Memory.write(pid, store, path, "value_#{i}", "string", i)
    end

    %{pid: pid, store: store}
  end

  test "count/2 returns number of entries", %{pid: pid, store: store} do
    assert Dust.Cache.Memory.count(pid, store) == 10
  end

  test "count/2 returns 0 for empty store", %{pid: pid} do
    assert Dust.Cache.Memory.count(pid, "empty/store") == 0
  end

  test "browse/3 returns first page", %{pid: pid, store: store} do
    {entries, cursor} = Dust.Cache.Memory.browse(pid, store, limit: 3)
    assert length(entries) == 3
    assert cursor != nil

    # Entries are {path, value, type, seq} tuples sorted by path
    [{path1, _, _, _} | _] = entries
    assert path1 == "items.item_01"
  end

  test "browse/3 paginates through all entries", %{pid: pid, store: store} do
    {page1, cursor1} = Dust.Cache.Memory.browse(pid, store, limit: 4)
    assert length(page1) == 4

    {page2, cursor2} = Dust.Cache.Memory.browse(pid, store, limit: 4, cursor: cursor1)
    assert length(page2) == 4

    {page3, cursor3} = Dust.Cache.Memory.browse(pid, store, limit: 4, cursor: cursor2)
    assert length(page3) == 2
    assert cursor3 == nil

    # No duplicates
    all_paths = Enum.map(page1 ++ page2 ++ page3, fn {path, _, _, _} -> path end)
    assert length(Enum.uniq(all_paths)) == 10
  end

  test "browse/3 filters by glob pattern", %{pid: pid, store: store} do
    # Add some entries outside the pattern
    Dust.Cache.Memory.write(pid, store, "other.thing", "x", "string", 11)

    {entries, _} = Dust.Cache.Memory.browse(pid, store, pattern: "items.*", limit: 100)
    assert length(entries) == 10
  end

  test "browse/3 with no options returns all sorted by path", %{pid: pid, store: store} do
    {entries, nil} = Dust.Cache.Memory.browse(pid, store, [])
    assert length(entries) == 10
    paths = Enum.map(entries, fn {path, _, _, _} -> path end)
    assert paths == Enum.sort(paths)
  end
end
