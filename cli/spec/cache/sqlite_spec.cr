require "../spec_helper"
require "../../src/dust/cache/sqlite"
require "../../src/dust/glob"

describe Dust::Cache do
  it "round-trips a string value" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "key", JSON::Any.new("hello"), "string", 1_i64)
    cache.read("store", "key").should eq JSON::Any.new("hello")
  end

  it "returns nil for missing key" do
    cache = Dust::Cache.new(":memory:")
    cache.read("store", "nope").should be_nil
  end

  it "delete removes entry" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "key", JSON::Any.new("val"), "string", 1_i64)
    cache.delete("store", "key")
    cache.read("store", "key").should be_nil
  end

  it "last_seq starts at 0" do
    cache = Dust::Cache.new(":memory:")
    cache.last_seq("store").should eq 0_i64
  end

  it "last_seq tracks highest seq" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a", JSON::Any.new("1"), "string", 5_i64)
    cache.write("store", "b", JSON::Any.new("2"), "string", 10_i64)
    cache.write("store", "c", JSON::Any.new("3"), "string", 3_i64)
    cache.last_seq("store").should eq 10_i64
  end

  it "last_seq survives deletion" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a", JSON::Any.new("1"), "string", 10_i64)
    cache.delete("store", "a")
    cache.last_seq("store").should eq 10_i64
  end

  it "read_all returns all entries" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a", JSON::Any.new("1"), "string", 1_i64)
    cache.write("store", "b", JSON::Any.new("2"), "string", 2_i64)
    results = cache.read_all("store")
    results.size.should eq 2
  end

  describe "#read_entry" do
    it "returns {value, type, seq} for present entries" do
      cache = Dust::Cache.new(":memory:")
      cache.write("store", "a.b", JSON::Any.new("hello"), "string", 7_i64)

      result = cache.read_entry("store", "a.b")
      result.should_not be_nil
      result.not_nil![:value].should eq JSON::Any.new("hello")
      result.not_nil![:type].should eq "string"
      result.not_nil![:seq].should eq 7_i64
    end

    it "returns nil for missing entries" do
      cache = Dust::Cache.new(":memory:")
      cache.read_entry("store", "missing").should be_nil
    end
  end

  describe "#read_many" do
    it "returns a hash of present entries" do
      cache = Dust::Cache.new(":memory:")
      cache.write("store", "a", JSON::Any.new(1_i64), "integer", 1_i64)
      cache.write("store", "b", JSON::Any.new(2_i64), "integer", 2_i64)

      result = cache.read_many("store", ["a", "b"])
      result.size.should eq 2
      result["a"][:value].should eq JSON::Any.new(1_i64)
      result["b"][:value].should eq JSON::Any.new(2_i64)
    end

    it "omits missing paths" do
      cache = Dust::Cache.new(":memory:")
      cache.write("store", "a", JSON::Any.new(1_i64), "integer", 1_i64)

      result = cache.read_many("store", ["a", "missing"])
      result.keys.should eq ["a"]
    end

    it "returns empty hash for empty paths list" do
      cache = Dust::Cache.new(":memory:")
      cache.read_many("store", [] of String).should be_empty
    end

    it "deduplicates input paths" do
      cache = Dust::Cache.new(":memory:")
      cache.write("store", "a", JSON::Any.new(1_i64), "integer", 1_i64)

      result = cache.read_many("store", ["a", "a", "a"])
      result.size.should eq 1
    end
  end

  describe "#browse" do
    it "returns entries matching pattern with default order asc and limit 50" do
      cache = Dust::Cache.new(":memory:")
      %w(a.1 a.2 a.3 b.1).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, cursor = cache.browse("store", pattern: "a.*", limit: 50)
      items.size.should eq 3
      items.map { |row| row.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["a.1", "a.2", "a.3"]
      cursor.should be_nil
    end

    it "honors limit and returns next_cursor" do
      cache = Dust::Cache.new(":memory:")
      %w(a b c d e).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, cursor = cache.browse("store", pattern: "**", limit: 2)
      items.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["a", "b"]
      cursor.should eq "b"
    end

    it "resumes from cursor" do
      cache = Dust::Cache.new(":memory:")
      %w(a b c d e).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, _ = cache.browse("store", pattern: "**", limit: 2, after: "b")
      items.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["c", "d"]
    end

    it "supports order: desc" do
      cache = Dust::Cache.new(":memory:")
      %w(a b c).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, _ = cache.browse("store", pattern: "**", limit: 10, order: "desc")
      items.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["c", "b", "a"]
    end

    it "supports select: keys" do
      cache = Dust::Cache.new(":memory:")
      cache.write("store", "a", JSON::Any.new("x"), "string", 1_i64)
      cache.write("store", "b", JSON::Any.new("y"), "string", 2_i64)

      items, _ = cache.browse("store", pattern: "**", limit: 10, select_as: "keys")
      items.should eq ["a", "b"]
    end

    it "supports select: prefixes for ** pattern" do
      cache = Dust::Cache.new(":memory:")
      %w(users.alice.name users.bob.name posts.hi).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, _ = cache.browse("store", pattern: "**", limit: 10, select_as: "prefixes")
      items.should eq ["posts", "users"]
    end

    it "supports select: prefixes for users.** pattern" do
      cache = Dust::Cache.new(":memory:")
      %w(users.alice.name users.alice.email users.bob.name).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, _ = cache.browse("store", pattern: "users.**", limit: 10, select_as: "prefixes")
      items.should eq ["users.alice", "users.bob"]
    end

    it "rejects select: prefixes with invalid pattern" do
      cache = Dust::Cache.new(":memory:")

      expect_raises(ArgumentError, /prefixes/) do
        cache.browse("store", pattern: "a.*.b", limit: 10, select_as: "prefixes")
      end
    end
  end

  describe "#browse with from/to range" do
    it "returns entries in [from, to)" do
      cache = Dust::Cache.new(":memory:")
      %w(a b c d e).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, _ = cache.browse("store", from: "b", to: "d", limit: 10)
      items.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["b", "c"]
    end

    it "from is inclusive, to is exclusive" do
      cache = Dust::Cache.new(":memory:")
      %w(a b c).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, _ = cache.browse("store", from: "a", to: "c", limit: 10)
      items.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["a", "b"]
    end

    it "from >= to returns empty" do
      cache = Dust::Cache.new(":memory:")
      cache.write("store", "x", JSON::Any.new("x"), "string", 1_i64)
      items, cursor = cache.browse("store", from: "z", to: "a", limit: 10)
      items.should be_empty
      cursor.should be_nil
    end

    it "range with limit + cursor paginates" do
      cache = Dust::Cache.new(":memory:")
      %w(a b c d e).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, cursor = cache.browse("store", from: "a", to: "z", limit: 2)
      items.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["a", "b"]
      cursor.should eq "b"

      items2, cursor2 = cache.browse("store", from: "a", to: "z", limit: 2, after: cursor)
      items2.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["c", "d"]
      cursor2.should eq "d"
    end

    it "range with order :desc" do
      cache = Dust::Cache.new(":memory:")
      %w(a b c d).each_with_index do |p, i|
        cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
      end

      items, _ = cache.browse("store", from: "a", to: "d", limit: 10, order: "desc")
      items.map { |r| r.as(NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64))[:path] }.should eq ["c", "b", "a"]
    end

    it "range rejects select_as: prefixes" do
      cache = Dust::Cache.new(":memory:")
      expect_raises(ArgumentError) do
        cache.browse("store", from: "a", to: "z", select_as: "prefixes")
      end
    end
  end
end
