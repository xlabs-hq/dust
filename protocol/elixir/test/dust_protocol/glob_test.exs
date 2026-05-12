defmodule DustProtocol.GlobTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Glob

  describe "compile/1" do
    test "compiles a segment-list pattern" do
      assert {:ok, {:compiled, _}} = Glob.compile(["posts", "*"])
    end

    test "compiles a rendered-string pattern" do
      assert {:ok, {:compiled, _}} = Glob.compile("posts/*")
    end

    test "rejects empty pattern" do
      assert Glob.compile([]) == {:error, :empty_path}
      assert Glob.compile("") == {:error, :empty_path}
    end

    test "rejects empty segment" do
      assert Glob.compile(["a", ""]) == {:error, :empty_segment}
      assert Glob.compile("a//b") == {:error, :empty_segment}
    end

    test "rejects ** in non-tail position" do
      assert Glob.compile(["a", "**", "b"]) == {:error, :wildcard_many_not_tail}
      assert Glob.compile("a/**/b") == {:error, :wildcard_many_not_tail}
    end

    test "accepts ** in tail position" do
      assert {:ok, _} = Glob.compile(["a", "**"])
      assert {:ok, _} = Glob.compile("a/**")
    end

    test "rejects invalid path escapes" do
      assert Glob.compile("a~") == {:error, :invalid_escape}
    end
  end

  describe "match?/2 — wildcards" do
    test "* matches exactly one segment" do
      assert Glob.match?(["posts", "*"], ["posts", "hello"])
      refute Glob.match?(["posts", "*"], ["posts"])
      refute Glob.match?(["posts", "*"], ["posts", "hello", "title"])
    end

    test "** at tail matches one-or-more segments" do
      assert Glob.match?(["posts", "**"], ["posts", "hello"])
      assert Glob.match?(["posts", "**"], ["posts", "a", "b", "c"])
      refute Glob.match?(["posts", "**"], ["posts"])
    end

    test "literal segments must match exactly" do
      assert Glob.match?(["a", "b", "c"], ["a", "b", "c"])
      refute Glob.match?(["a", "b", "c"], ["a", "b", "d"])
    end

    test "* mid-pattern" do
      assert Glob.match?(["a", "*", "c"], ["a", "b", "c"])
      refute Glob.match?(["a", "*", "c"], ["a", "b", "d"])
    end
  end

  describe "match?/2 — literal characters" do
    test "dots are literal" do
      assert Glob.match?(["hello.world"], ["hello.world"])
      refute Glob.match?(["hello.world"], ["hello", "world"])
    end

    test "slashes in segments work (need ~1 in rendered form)" do
      assert Glob.match?(["files", "image/file"], ["files", "image/file"])
      assert Glob.match?("files/image~1file", ["files", "image/file"])
    end

    test "tildes in segments work" do
      assert Glob.match?(["a~b"], ["a~b"])
      assert Glob.match?("a~0b", ["a~b"])
    end
  end

  describe "match?/2 — literal wildcard escapes" do
    test "\\* matches literal asterisk segment" do
      assert Glob.match?(["a", "\\*"], ["a", "*"])
      refute Glob.match?(["a", "\\*"], ["a", "x"])
    end

    test "\\** matches literal double-asterisk segment" do
      assert Glob.match?(["a", "\\**"], ["a", "**"])
      refute Glob.match?(["a", "\\**"], ["a", "x", "y"])
    end
  end

  describe "match?/2 — accepts rendered string patterns" do
    test "rendered string is compiled on the fly" do
      assert Glob.match?("posts/*", ["posts", "hello"])
      refute Glob.match?("posts/*", ["posts", "hello", "title"])
    end

    test "compile error in match? raises" do
      assert_raise ArgumentError, ~r/invalid glob pattern/, fn ->
        Glob.match?("a/**/b", ["a", "b"])
      end
    end
  end

  describe "compile!/1" do
    test "returns the compiled pattern" do
      assert {:compiled, _} = Glob.compile!(["a", "*"])
    end

    test "raises on invalid pattern" do
      assert_raise ArgumentError, ~r/invalid glob pattern/, fn ->
        Glob.compile!(["a", "**", "b"])
      end
    end
  end

  describe "fixture conformance (protocol/spec/fixtures/glob_vectors.json)" do
    @fixture_path Elixir.Path.expand(
                    Elixir.Path.join([
                      __DIR__,
                      "..",
                      "..",
                      "..",
                      "spec",
                      "fixtures",
                      "glob_vectors.json"
                    ])
                  )

    @vectors @fixture_path |> File.read!() |> :json.decode()

    for {vector, idx} <- Enum.with_index(@vectors) do
      case vector do
        %{
          "valid" => true,
          "pattern_segments" => p_segs,
          "pattern_rendered" => p_str,
          "path" => path,
          "match" => expected
        } ->
          @vector_idx idx
          @p_segs p_segs
          @p_str p_str
          @path path
          @expected expected

          test "vector ##{@vector_idx}: #{inspect(@p_segs)} vs #{inspect(@path)} -> #{@expected}" do
            # Both forms must give the same result.
            seg_result = Glob.match?(@p_segs, @path)
            str_result = Glob.match?(@p_str, @path)
            assert seg_result == @expected
            assert str_result == @expected
          end

        %{"valid" => false, "pattern_rendered" => p_str, "error" => error} ->
          @vector_idx idx
          @p_str p_str
          @vector_error String.to_atom(error)

          test "vector ##{@vector_idx}: pattern #{inspect(@p_str)} rejected with :#{@vector_error}" do
            assert {:error, @vector_error} = Glob.compile(@p_str)
          end
      end
    end
  end
end
