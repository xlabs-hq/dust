defmodule Dust.GlobTest do
  use ExUnit.Case, async: true

  describe "match?/2" do
    test "** matches any path (empty, single, deep)" do
      assert Dust.Glob.match?("", "**")
      assert Dust.Glob.match?("a", "**")
      assert Dust.Glob.match?("a.b.c.d", "**")
    end

    test "literal pattern matches exactly" do
      assert Dust.Glob.match?("users.alice.name", "users.alice.name")
      refute Dust.Glob.match?("users.alice.name", "users.alice.email")
    end

    test "a.* matches direct children only" do
      assert Dust.Glob.match?("users.alice", "users.*")
      refute Dust.Glob.match?("users.alice.name", "users.*")
      refute Dust.Glob.match?("users", "users.*")
    end

    test "a.** matches the parent plus any descendants" do
      assert Dust.Glob.match?("users", "users.**")
      assert Dust.Glob.match?("users.alice", "users.**")
      assert Dust.Glob.match?("users.alice.name", "users.**")
      refute Dust.Glob.match?("posts.hello", "users.**")
    end

    test "interior wildcard a.*.b" do
      assert Dust.Glob.match?("users.alice.name", "users.*.name")
      assert Dust.Glob.match?("users.bob.name", "users.*.name")
      refute Dust.Glob.match?("users.alice.email", "users.*.name")
      refute Dust.Glob.match?("users.alice.profile.name", "users.*.name")
    end

    test "pattern longer than path returns false" do
      refute Dust.Glob.match?("users", "users.alice.name")
    end

    test "path longer than literal pattern returns false" do
      refute Dust.Glob.match?("users.alice", "users")
    end
  end
end
