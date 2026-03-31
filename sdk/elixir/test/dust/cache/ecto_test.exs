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
end
