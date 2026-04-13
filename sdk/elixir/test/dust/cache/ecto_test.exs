defmodule Dust.Cache.EctoTest do
  use ExUnit.Case, async: false

  alias Dust.Cache.Ecto, as: EctoCache

  @store "test-store"

  setup do
    # Clean the table between tests
    Dust.TestRepo.delete_all(Dust.Cache.Ecto.CacheEntry)
    :ok
  end

  describe "write and read" do
    test "round-trips a string value" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1.name", "Alice", "string", 1)
      assert {:ok, "Alice"} = EctoCache.read(Dust.TestRepo, @store, "users.1.name")
    end

    test "round-trips a map value" do
      value = %{"name" => "Alice", "age" => 30}
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1", value, "map", 1)
      assert {:ok, ^value} = EctoCache.read(Dust.TestRepo, @store, "users.1")
    end

    test "round-trips an integer value" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "counter", 42, "integer", 1)
      assert {:ok, 42} = EctoCache.read(Dust.TestRepo, @store, "counter")
    end

    test "round-trips a boolean value" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "flag", true, "boolean", 1)
      assert {:ok, true} = EctoCache.read(Dust.TestRepo, @store, "flag")
    end

    test "upserts on duplicate store+path" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "key", "old", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "key", "new", "string", 2)
      assert {:ok, "new"} = EctoCache.read(Dust.TestRepo, @store, "key")
    end
  end

  describe "read" do
    test "returns :miss for unknown path" do
      assert :miss = EctoCache.read(Dust.TestRepo, @store, "nonexistent")
    end

    test "returns :miss for wrong store" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "key", "val", "string", 1)
      assert :miss = EctoCache.read(Dust.TestRepo, "other-store", "key")
    end
  end

  describe "read_entry" do
    test "returns full metadata for present keys" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "a.b", "hello", "string", 7)

      assert EctoCache.read_entry(Dust.TestRepo, @store, "a.b") ==
               {:ok, {"hello", "string", 7}}
    end

    test "decodes non-string json values" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "m", %{"k" => 1}, "map", 3)

      assert EctoCache.read_entry(Dust.TestRepo, @store, "m") ==
               {:ok, {%{"k" => 1}, "map", 3}}
    end

    test "returns :miss for absent keys" do
      assert EctoCache.read_entry(Dust.TestRepo, @store, "nope") == :miss
    end
  end

  describe "delete" do
    test "removes an entry" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "key", "val", "string", 1)
      assert {:ok, "val"} = EctoCache.read(Dust.TestRepo, @store, "key")

      :ok = EctoCache.delete(Dust.TestRepo, @store, "key")
      assert :miss = EctoCache.read(Dust.TestRepo, @store, "key")
    end

    test "is a no-op for missing key" do
      assert :ok = EctoCache.delete(Dust.TestRepo, @store, "nonexistent")
    end
  end

  describe "last_seq" do
    test "starts at 0 when store is empty" do
      assert 0 = EctoCache.last_seq(Dust.TestRepo, @store)
    end

    test "tracks the highest seq for a store" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "a", "1", "string", 5)
      :ok = EctoCache.write(Dust.TestRepo, @store, "b", "2", "string", 10)
      :ok = EctoCache.write(Dust.TestRepo, @store, "c", "3", "string", 3)

      assert 10 = EctoCache.last_seq(Dust.TestRepo, @store)
    end

    test "is scoped to the store" do
      :ok = EctoCache.write(Dust.TestRepo, "store-a", "key", "v", "string", 100)
      :ok = EctoCache.write(Dust.TestRepo, "store-b", "key", "v", "string", 5)

      assert 100 = EctoCache.last_seq(Dust.TestRepo, "store-a")
      assert 5 = EctoCache.last_seq(Dust.TestRepo, "store-b")
    end

    test "survives deletion of the latest entry" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "a", "v1", "string", 5)
      :ok = EctoCache.write(Dust.TestRepo, @store, "b", "v2", "string", 10)

      # Delete the entry with the highest seq
      :ok = EctoCache.delete(Dust.TestRepo, @store, "b")

      # last_seq should still be 10, not drop to 5
      assert 10 = EctoCache.last_seq(Dust.TestRepo, @store)
    end

    test "survives deletion of all entries" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "only", "v", "string", 7)
      :ok = EctoCache.delete(Dust.TestRepo, @store, "only")

      # last_seq should still be 7, not drop to 0
      assert 7 = EctoCache.last_seq(Dust.TestRepo, @store)
    end
  end

  describe "read_all" do
    test "returns matching entries by glob pattern" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1.name", "Alice", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.2.name", "Bob", "string", 2)
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1.age", 30, "integer", 3)
      :ok = EctoCache.write(Dust.TestRepo, @store, "posts.1.title", "Hello", "string", 4)

      results = EctoCache.read_all(Dust.TestRepo, @store, "users.*.name")
      assert length(results) == 2

      result_map = Map.new(results)
      assert result_map["users.1.name"] == "Alice"
      assert result_map["users.2.name"] == "Bob"
    end

    test "returns all entries with double-star glob" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1.name", "Alice", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.2.name", "Bob", "string", 2)
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1.age", 30, "integer", 3)

      results = EctoCache.read_all(Dust.TestRepo, @store, "users.**")
      assert length(results) == 3
    end

    test "returns empty list when nothing matches" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1.name", "Alice", "string", 1)

      results = EctoCache.read_all(Dust.TestRepo, @store, "posts.**")
      assert results == []
    end

    test "is scoped to the store" do
      :ok = EctoCache.write(Dust.TestRepo, "store-a", "key", "a", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, "store-b", "key", "b", "string", 1)

      results = EctoCache.read_all(Dust.TestRepo, "store-a", "**")
      assert length(results) == 1
      assert [{"key", "a"}] = results
    end
  end

  describe "write_batch" do
    test "writes multiple entries at once" do
      entries = [
        {"users.1.name", "Alice", "string", 1},
        {"users.2.name", "Bob", "string", 2},
        {"users.3.name", "Carol", "string", 3}
      ]

      :ok = EctoCache.write_batch(Dust.TestRepo, @store, entries)

      assert {:ok, "Alice"} = EctoCache.read(Dust.TestRepo, @store, "users.1.name")
      assert {:ok, "Bob"} = EctoCache.read(Dust.TestRepo, @store, "users.2.name")
      assert {:ok, "Carol"} = EctoCache.read(Dust.TestRepo, @store, "users.3.name")
    end

    test "updates last_seq to the highest in the batch" do
      entries = [
        {"a", "1", "string", 5},
        {"b", "2", "string", 15},
        {"c", "3", "string", 10}
      ]

      :ok = EctoCache.write_batch(Dust.TestRepo, @store, entries)
      assert 15 = EctoCache.last_seq(Dust.TestRepo, @store)
    end

    test "upserts existing entries" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "key", "old", "string", 1)

      entries = [
        {"key", "new", "string", 2},
        {"other", "val", "string", 3}
      ]

      :ok = EctoCache.write_batch(Dust.TestRepo, @store, entries)

      assert {:ok, "new"} = EctoCache.read(Dust.TestRepo, @store, "key")
      assert {:ok, "val"} = EctoCache.read(Dust.TestRepo, @store, "other")
    end

    test "handles empty batch" do
      assert :ok = EctoCache.write_batch(Dust.TestRepo, @store, [])
    end
  end

  describe "browse order" do
    test "desc order returns entries in reverse lex order" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "a", "1", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "b", "2", "string", 2)
      :ok = EctoCache.write(Dust.TestRepo, @store, "c", "3", "string", 3)

      {page, next_cursor} = EctoCache.browse(Dust.TestRepo, @store, order: :desc)

      paths = Enum.map(page, fn {p, _, _, _} -> p end)
      assert paths == ["c", "b", "a"]
      assert next_cursor == nil
    end

    test "desc + cursor drops entries >= cursor" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "a", "1", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "b", "2", "string", 2)
      :ok = EctoCache.write(Dust.TestRepo, @store, "c", "3", "string", 3)
      :ok = EctoCache.write(Dust.TestRepo, @store, "d", "4", "string", 4)

      {page, _next_cursor} =
        EctoCache.browse(Dust.TestRepo, @store, order: :desc, cursor: "c")

      paths = Enum.map(page, fn {p, _, _, _} -> p end)
      assert paths == ["b", "a"]
    end
  end

  describe "browse select" do
    test "select: :entries (default) returns decoded 4-tuples" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.1.name", "Alice", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "users.2.name", "Bob", "string", 2)

      {page, _next_cursor} = EctoCache.browse(Dust.TestRepo, @store, [])

      assert [
               {"users.1.name", "Alice", "string", 1},
               {"users.2.name", "Bob", "string", 2}
             ] = page
    end

    test "select: :keys returns a list of path strings in order" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "b", "2", "string", 2)
      :ok = EctoCache.write(Dust.TestRepo, @store, "a", "1", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "c", "3", "string", 3)

      {page, next_cursor} = EctoCache.browse(Dust.TestRepo, @store, select: :keys)

      assert page == ["a", "b", "c"]
      assert next_cursor == nil
    end

    test "select: :keys respects limit and order" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "a", "1", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "b", "2", "string", 2)
      :ok = EctoCache.write(Dust.TestRepo, @store, "c", "3", "string", 3)

      {page, next_cursor} =
        EctoCache.browse(Dust.TestRepo, @store, select: :keys, order: :desc, limit: 2)

      assert page == ["c", "b"]
      assert next_cursor == "b"
    end

    test "select: :prefixes with pattern ** returns unique top-level segments" do
      for p <- ~w(users.alice.name users.bob.name posts.hi),
          do: :ok = EctoCache.write(Dust.TestRepo, @store, p, 1, "integer", 1)

      {items, _} =
        EctoCache.browse(Dust.TestRepo, @store, pattern: "**", select: :prefixes, limit: 10)

      assert items == ~w(posts users)
    end

    test "select: :prefixes with pattern 'users.**' returns unique next-segment prefixes" do
      for p <- ~w(users.alice.name users.alice.email users.bob.name),
          do: :ok = EctoCache.write(Dust.TestRepo, @store, p, 1, "integer", 1)

      {items, _} =
        EctoCache.browse(Dust.TestRepo, @store,
          pattern: "users.**",
          select: :prefixes,
          limit: 10
        )

      assert items == ~w(users.alice users.bob)
    end
  end

  describe "browse pagination with narrow glob" do
    test "paginates narrow glob over wide raw prefix without dropping matches" do
      # Seed 60 decoy entries that sort BEFORE the matches so a naive limit+1
      # raw fetch captures 51 decoys and zero matches.
      for i <- 1..60 do
        suffix = String.pad_leading(to_string(i), 3, "0")

        :ok =
          EctoCache.write(
            Dust.TestRepo,
            @store,
            "logs.server.alpha.#{suffix}",
            "alpha-#{suffix}",
            "string",
            i
          )
      end

      # Seed 3 entries that actually match the narrow glob
      for i <- 1..3 do
        :ok =
          EctoCache.write(
            Dust.TestRepo,
            @store,
            "logs.server.error.#{i}",
            "error-#{i}",
            "string",
            100 + i
          )
      end

      # Walk pages following next_cursor until exhausted.
      walk = fn cursor, acc, pages, walk ->
        {page, next_cursor} =
          EctoCache.browse(Dust.TestRepo, @store,
            pattern: "logs.*.error.**",
            select: :keys,
            limit: 50,
            cursor: cursor
          )

        new_acc = acc ++ page

        case next_cursor do
          nil -> {new_acc, pages + 1}
          c -> walk.(c, new_acc, pages + 1, walk)
        end
      end

      {all_items, page_count} = walk.(nil, [], 0, walk)

      assert Enum.sort(all_items) == [
               "logs.server.error.1",
               "logs.server.error.2",
               "logs.server.error.3"
             ]

      assert page_count <= 2
    end

    test "I1 regression: literal '%' in pattern prefix returns only exact matches" do
      :ok = EctoCache.write(Dust.TestRepo, @store, "weird%.child", "match", "string", 1)
      :ok = EctoCache.write(Dust.TestRepo, @store, "weirdX.child", "decoy", "string", 2)

      {items, _} =
        EctoCache.browse(Dust.TestRepo, @store,
          pattern: "weird%.**",
          select: :keys,
          limit: 10
        )

      assert items == ["weird%.child"]
    end
  end
end
