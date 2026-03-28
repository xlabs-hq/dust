defmodule DustProtocol.GlobTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Glob

  describe "match?/2" do
    test "exact path matches" do
      assert Glob.match?("config.timeout", ["config", "timeout"])
    end

    test "exact path does not match different path" do
      refute Glob.match?("config.timeout", ["config", "retries"])
    end

    test "* matches one segment" do
      assert Glob.match?("posts.*", ["posts", "hello"])
    end

    test "* does not match zero segments" do
      refute Glob.match?("posts.*", ["posts"])
    end

    test "* does not match multiple segments" do
      refute Glob.match?("posts.*", ["posts", "hello", "title"])
    end

    test "** matches one segment" do
      assert Glob.match?("posts.**", ["posts", "hello"])
    end

    test "** matches multiple segments" do
      assert Glob.match?("posts.**", ["posts", "hello", "title"])
    end

    test "** matches deeply nested" do
      assert Glob.match?("posts.**", ["posts", "archive", "2024", "jan"])
    end

    test "** does not match zero segments" do
      refute Glob.match?("posts.**", ["posts"])
    end

    test "mixed pattern" do
      assert Glob.match?("users.*.settings", ["users", "alice", "settings"])
      refute Glob.match?("users.*.settings", ["users", "alice", "bob", "settings"])
    end

    test "** in middle of pattern" do
      assert Glob.match?("a.**.z", ["a", "b", "c", "z"])
      assert Glob.match?("a.**.z", ["a", "b", "z"])
      refute Glob.match?("a.**.z", ["a", "z"])
    end
  end

  describe "compile/1" do
    test "compiled pattern matches same as string pattern" do
      compiled = Glob.compile("posts.*")
      assert Glob.match?(compiled, ["posts", "hello"])
      refute Glob.match?(compiled, ["posts", "hello", "title"])
    end
  end
end
