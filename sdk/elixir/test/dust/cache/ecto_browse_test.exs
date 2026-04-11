defmodule Dust.Cache.EctoBrowseTest do
  use ExUnit.Case, async: false

  alias Dust.Cache.Ecto, as: EctoCache

  setup do
    Dust.TestRepo.delete_all(Dust.Cache.Ecto.CacheEntry)
    store = "test/browse_store"

    for i <- 1..10 do
      path = "items.item_#{String.pad_leading(to_string(i), 2, "0")}"
      EctoCache.write(Dust.TestRepo, store, path, "value_#{i}", "string", i)
    end

    %{store: store}
  end

  test "count/2 returns entry count excluding sentinel", %{store: store} do
    assert EctoCache.count(Dust.TestRepo, store) == 10
  end

  test "browse/3 paginates with keyset cursor", %{store: store} do
    {page1, cursor1} = EctoCache.browse(Dust.TestRepo, store, limit: 4)
    assert length(page1) == 4

    {page2, cursor2} = EctoCache.browse(Dust.TestRepo, store, limit: 4, cursor: cursor1)
    assert length(page2) == 4

    {page3, cursor3} = EctoCache.browse(Dust.TestRepo, store, limit: 4, cursor: cursor2)
    assert length(page3) == 2
    assert cursor3 == nil

    all_paths = Enum.map(page1 ++ page2 ++ page3, fn {path, _, _, _} -> path end)
    assert length(Enum.uniq(all_paths)) == 10
  end

  test "browse/3 filters by glob pattern", %{store: store} do
    EctoCache.write(Dust.TestRepo, store, "other.thing", "x", "string", 11)

    {entries, _} = EctoCache.browse(Dust.TestRepo, store, pattern: "items.*", limit: 100)
    assert length(entries) == 10
  end
end
