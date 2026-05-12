defmodule DustProtocol.PathTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Path

  describe "from_segments/1" do
    test "validates a non-empty list of non-empty strings" do
      assert Path.from_segments(["a", "b"]) == {:ok, ["a", "b"]}
    end

    test "preserves dots inside a segment" do
      assert Path.from_segments(["hello.world"]) == {:ok, ["hello.world"]}
    end

    test "preserves slashes and tildes inside a segment" do
      assert Path.from_segments(["a/b", "c~d"]) == {:ok, ["a/b", "c~d"]}
    end

    test "rejects empty list" do
      assert Path.from_segments([]) == {:error, :empty_path}
    end

    test "rejects list with an empty segment" do
      assert Path.from_segments(["a", "", "b"]) == {:error, :empty_segment}
    end

    test "rejects non-list input" do
      assert Path.from_segments("not a list") == {:error, :not_a_list}
    end

    test "rejects list with non-binary segment" do
      assert Path.from_segments(["a", 42, "b"]) == {:error, :not_a_string}
    end
  end

  describe "render/1" do
    test "joins valid segments with slashes" do
      assert Path.render(["a", "b", "c"]) == {:ok, "a/b/c"}
    end

    test "leaves dots literal in rendered form" do
      assert Path.render(["hello.world"]) == {:ok, "hello.world"}
    end

    test "escapes literal slash as ~1" do
      assert Path.render(["files", "image/file"]) == {:ok, "files/image~1file"}
    end

    test "escapes literal tilde as ~0" do
      assert Path.render(["a~b"]) == {:ok, "a~0b"}
    end

    test "encodes tilde before slash (correct escape order)" do
      assert Path.render(["a/b~c"]) == {:ok, "a~1b~0c"}
    end

    test "rejects invalid input" do
      assert Path.render([]) == {:error, :empty_path}
      assert Path.render(["a", ""]) == {:error, :empty_segment}
    end
  end

  describe "parse_rendered/1" do
    test "splits on slash" do
      assert Path.parse_rendered("a/b/c") == {:ok, ["a", "b", "c"]}
    end

    test "treats dots as literal" do
      assert Path.parse_rendered("hello.world") == {:ok, ["hello.world"]}
    end

    test "decodes ~1 back to /" do
      assert Path.parse_rendered("files/image~1file") == {:ok, ["files", "image/file"]}
    end

    test "decodes ~0 back to ~" do
      assert Path.parse_rendered("a~0b") == {:ok, ["a~b"]}
    end

    test "rejects empty string" do
      assert Path.parse_rendered("") == {:error, :empty_path}
    end

    test "rejects leading slash (empty first segment)" do
      assert Path.parse_rendered("/a") == {:error, :empty_segment}
    end

    test "rejects trailing slash" do
      assert Path.parse_rendered("a/") == {:error, :empty_segment}
    end

    test "rejects double slash" do
      assert Path.parse_rendered("a//b") == {:error, :empty_segment}
    end

    test "rejects bare ~" do
      assert Path.parse_rendered("a~") == {:error, :invalid_escape}
    end

    test "rejects ~ followed by anything other than 0 or 1" do
      assert Path.parse_rendered("a~b") == {:error, :invalid_escape}
      assert Path.parse_rendered("a~2b") == {:error, :invalid_escape}
    end
  end

  describe "round trip" do
    test "render then parse returns the original segments" do
      for segments <- [
            ["a", "b", "c"],
            ["hello.world"],
            ["files", "image/file"],
            ["a~b", "c/d"],
            ["~~~~"],
            ["//"]
          ] do
        assert {:ok, rendered} = Path.render(segments)
        assert {:ok, ^segments} = Path.parse_rendered(rendered)
      end
    end

    test "parse then render returns the canonical rendered form" do
      for rendered <- [
            "a/b/c",
            "hello.world",
            "files/image~1file",
            "a~0b/c~1d",
            "~0~0",
            "~1~1"
          ] do
        assert {:ok, segments} = Path.parse_rendered(rendered)
        assert {:ok, ^rendered} = Path.render(segments)
      end
    end
  end

  describe "normalize_rendered/1" do
    test "returns the canonical form of a valid rendered path" do
      assert Path.normalize_rendered("a/b/c") == {:ok, "a/b/c"}
    end

    test "propagates parse errors" do
      assert Path.normalize_rendered("a//b") == {:error, :empty_segment}
      assert Path.normalize_rendered("a~") == {:error, :invalid_escape}
    end
  end

  describe "from_input/1" do
    test "accepts a rendered string" do
      assert Path.from_input("a/b/c") == {:ok, ["a", "b", "c"]}
    end

    test "accepts a segment list" do
      assert Path.from_input(["a", "b"]) == {:ok, ["a", "b"]}
    end

    test "rejects neither-string-nor-list input" do
      assert Path.from_input(42) == {:error, :not_a_string}
    end
  end

  describe "child/2" do
    test "appends a single segment literally" do
      assert Path.child(["posts"], "image/file") == {:ok, ["posts", "image/file"]}
    end

    test "preserves dots in the child segment" do
      assert Path.child(["users"], "alice@example.com") ==
               {:ok, ["users", "alice@example.com"]}
    end

    test "rejects empty child segment" do
      assert Path.child(["posts"], "") == {:error, :empty_segment}
    end

    test "rejects invalid parent" do
      assert Path.child([], "x") == {:error, :empty_path}
    end
  end

  describe "concat/2" do
    test "appends a segment list" do
      assert Path.concat(["a"], ["b", "c"]) == {:ok, ["a", "b", "c"]}
    end

    test "preserves literal characters in concatenated segments" do
      assert Path.concat(["reading", "links"], ["foo.bar", "x/y"]) ==
               {:ok, ["reading", "links", "foo.bar", "x/y"]}
    end
  end

  describe "ancestor?/2" do
    test "parent is ancestor of child" do
      assert Path.ancestor?(["a"], ["a", "b"])
    end

    test "grandparent is ancestor of grandchild" do
      assert Path.ancestor?(["a"], ["a", "b", "c"])
    end

    test "path is not its own ancestor" do
      refute Path.ancestor?(["a"], ["a"])
    end

    test "child is not ancestor of parent" do
      refute Path.ancestor?(["a", "b"], ["a"])
    end

    test "shares-a-prefix-byte but different segment is NOT ancestor" do
      # Critical: the previous string-prefix model would have treated
      # "post" as an ancestor of "posts/x" because of the byte prefix.
      # Segments-first kills that bug.
      refute Path.ancestor?(["post"], ["posts", "x"])
    end
  end

  describe "render_descendant_prefix/1" do
    test "trailing slash for SQL LIKE prefix matches" do
      assert Path.render_descendant_prefix(["posts", "hello.world"]) ==
               {:ok, "posts/hello.world/"}
    end

    test "escapes slashes in segments so the trailing / can't false-match" do
      assert Path.render_descendant_prefix(["files", "a/b"]) == {:ok, "files/a~1b/"}
    end
  end

  describe "fixture conformance (protocol/spec/fixtures/path_vectors.json)" do
    @fixture_path Elixir.Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "..",
                    "spec",
                    "fixtures",
                    "path_vectors.json"
                  ])
                  |> Elixir.Path.expand()

    @vectors @fixture_path |> File.read!() |> :json.decode()

    for {vector, idx} <- Enum.with_index(@vectors) do
      case vector do
        %{"valid" => true, "segments" => segments, "rendered" => rendered} ->
          @vector_idx idx
          @vector_segments segments
          @vector_rendered rendered

          test "vector ##{@vector_idx}: #{inspect(@vector_segments)} <-> #{inspect(@vector_rendered)}" do
            assert {:ok, @vector_rendered} = Path.render(@vector_segments)
            assert {:ok, @vector_segments} = Path.parse_rendered(@vector_rendered)
          end

        %{"valid" => false, "rendered" => rendered, "error" => error} ->
          @vector_idx idx
          @vector_rendered rendered
          @vector_error String.to_atom(error)

          test "vector ##{@vector_idx}: #{inspect(@vector_rendered)} rejected with :#{@vector_error}" do
            assert {:error, @vector_error} = Path.parse_rendered(@vector_rendered)
          end
      end
    end
  end
end
