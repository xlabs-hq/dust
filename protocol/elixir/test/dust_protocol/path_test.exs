defmodule DustProtocol.PathTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Path

  describe "parse/1" do
    test "parses dotted path into segments" do
      assert Path.parse("posts.hello.title") == {:ok, ["posts", "hello", "title"]}
    end

    test "parses single segment" do
      assert Path.parse("config") == {:ok, ["config"]}
    end

    test "rejects empty string" do
      assert Path.parse("") == {:error, :empty_path}
    end

    test "rejects path with empty segment" do
      assert Path.parse("posts..hello") == {:error, :empty_segment}
    end

    test "rejects path with leading dot" do
      assert Path.parse(".posts") == {:error, :empty_segment}
    end

    test "rejects path with trailing dot" do
      assert Path.parse("posts.") == {:error, :empty_segment}
    end
  end

  describe "to_string/1" do
    test "joins segments with dots" do
      assert Path.to_string(["posts", "hello", "title"]) == "posts.hello.title"
    end
  end

  describe "ancestor?/2" do
    test "parent is ancestor of child" do
      assert Path.ancestor?(["posts"], ["posts", "hello"])
    end

    test "grandparent is ancestor of grandchild" do
      assert Path.ancestor?(["posts"], ["posts", "hello", "title"])
    end

    test "path is not its own ancestor" do
      refute Path.ancestor?(["posts"], ["posts"])
    end

    test "child is not ancestor of parent" do
      refute Path.ancestor?(["posts", "hello"], ["posts"])
    end

    test "unrelated paths are not ancestors" do
      refute Path.ancestor?(["posts"], ["config"])
    end
  end

  describe "related?/2" do
    test "same path is related" do
      assert Path.related?(["posts"], ["posts"])
    end

    test "ancestor-descendant is related" do
      assert Path.related?(["posts"], ["posts", "hello"])
    end

    test "descendant-ancestor is related" do
      assert Path.related?(["posts", "hello"], ["posts"])
    end

    test "unrelated paths are not related" do
      refute Path.related?(["posts"], ["config"])
    end
  end
end
