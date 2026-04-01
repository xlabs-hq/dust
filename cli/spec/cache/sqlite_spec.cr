require "../spec_helper"
require "../../src/dust/cache/sqlite"

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
end
