require "./spec_helper"
require "../src/dust/path"
require "json"

describe Dust::Path do
  describe ".from_segments" do
    it "accepts a non-empty array of non-empty strings" do
      Dust::Path.from_segments(["a", "b"]).should eq ["a", "b"]
    end

    it "preserves dots inside segments" do
      Dust::Path.from_segments(["hello.world"]).should eq ["hello.world"]
    end

    it "rejects empty array" do
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.from_segments([] of String) }
    end

    it "rejects empty segment" do
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.from_segments(["a", "", "b"]) }
    end
  end

  describe ".render" do
    it "joins segments with slashes" do
      Dust::Path.render(["a", "b", "c"]).should eq "a/b/c"
    end

    it "leaves dots literal" do
      Dust::Path.render(["hello.world"]).should eq "hello.world"
    end

    it "escapes literal slash as ~1" do
      Dust::Path.render(["files", "image/file"]).should eq "files/image~1file"
    end

    it "escapes literal tilde as ~0" do
      Dust::Path.render(["a~b"]).should eq "a~0b"
    end

    it "encodes tilde before slash (correct escape order)" do
      Dust::Path.render(["a/b~c"]).should eq "a~1b~0c"
    end
  end

  describe ".parse_rendered" do
    it "splits on slash, dots stay literal" do
      Dust::Path.parse_rendered("a/b/c").should eq ["a", "b", "c"]
      Dust::Path.parse_rendered("hello.world").should eq ["hello.world"]
    end

    it "decodes ~1 -> / and ~0 -> ~" do
      Dust::Path.parse_rendered("files/image~1file").should eq ["files", "image/file"]
      Dust::Path.parse_rendered("a~0b").should eq ["a~b"]
    end

    it "rejects empty string" do
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered("") }
    end

    it "rejects leading / trailing / double slash" do
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered("/a") }
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered("a/") }
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered("a//b") }
    end

    it "rejects bare or invalid ~ escapes" do
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered("a~") }
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered("a~b") }
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered("a~2b") }
    end
  end

  describe "round trip" do
    it "render then parse returns the original segments" do
      cases = [
        ["a", "b", "c"],
        ["hello.world"],
        ["files", "image/file"],
        ["a~b", "c/d"],
        ["~~~~"],
        ["//"],
      ]
      cases.each do |segs|
        rendered = Dust::Path.render(segs)
        Dust::Path.parse_rendered(rendered).should eq segs
      end
    end
  end

  describe ".child / .concat" do
    it "child appends literally" do
      Dust::Path.child(["posts"], "image/file").should eq ["posts", "image/file"]
    end

    it "concat appends a segment array" do
      Dust::Path.concat(["a"], ["b", "c"]).should eq ["a", "b", "c"]
    end

    it "child rejects empty new segment" do
      expect_raises(Dust::Path::InvalidPathError) { Dust::Path.child(["a"], "") }
    end
  end

  describe ".ancestor?" do
    it "parent is ancestor of child" do
      Dust::Path.ancestor?(["a"], ["a", "b"]).should be_true
    end

    it "path is not its own ancestor" do
      Dust::Path.ancestor?(["a"], ["a"]).should be_false
    end

    it "byte-prefix that crosses segment boundary is NOT ancestor" do
      # Segment-aware: ["post"] is not an ancestor of ["posts", "x"]
      # even though "post" is a byte prefix of "posts".
      Dust::Path.ancestor?(["post"], ["posts", "x"]).should be_false
    end
  end

  describe ".render_descendant_prefix" do
    it "trailing slash for SQL-LIKE prefix matches" do
      Dust::Path.render_descendant_prefix(["posts", "hello.world"]).should eq "posts/hello.world/"
    end

    it "escapes slashes in segments" do
      Dust::Path.render_descendant_prefix(["files", "a/b"]).should eq "files/a~1b/"
    end
  end

  describe "legacy helpers" do
    it ".parse_legacy_dotted splits on dots (explicit opt-in)" do
      Dust::Path.parse_legacy_dotted("a.b.c").should eq ["a", "b", "c"]
    end

    it ".normalize_path: canonical slash -> unchanged" do
      Dust::Path.normalize_path("a/b/c").should eq "a/b/c"
    end

    it ".normalize_path: string with literal dots is one segment, not split" do
      # Capver 3: dots are literal in segments. Callers that hold
      # genuinely-legacy dotted strings must convert explicitly via
      # `parse_legacy_dotted` first.
      Dust::Path.normalize_path("example.com").should eq "example.com"
      Dust::Path.render(Dust::Path.parse_legacy_dotted("a.b.c")).should eq "a/b/c"
    end

    it ".normalize_pattern: ** passes through" do
      Dust::Path.normalize_pattern("**").should eq "**"
    end

    it ".normalize_pattern: canonical slash patterns pass through" do
      Dust::Path.normalize_pattern("foo/*").should eq "foo/*"
      Dust::Path.normalize_pattern("users/**").should eq "users/**"
    end
  end

  # --------------------------------------------------------------------
  # Fixture-driven conformance against the canonical protocol package.
  # Same JSON file is read by the Elixir SDK, TS SDK, and the canonical
  # protocol tests — divergence between ports fails identically.
  # --------------------------------------------------------------------

  describe "fixture conformance (protocol/spec/fixtures/path_vectors.json)" do
    fixture_path = File.expand_path("../../protocol/spec/fixtures/path_vectors.json", __DIR__)
    vectors = JSON.parse(File.read(fixture_path)).as_a

    vectors.each_with_index do |raw, idx|
      v = raw.as_h
      valid = v["valid"].as_bool

      if valid
        segments = v["segments"].as_a.map(&.as_s)
        rendered = v["rendered"].as_s

        it "##{idx}: #{segments.inspect} <-> #{rendered.inspect}" do
          Dust::Path.render(segments).should eq rendered
          Dust::Path.parse_rendered(rendered).should eq segments
        end
      else
        rendered = v["rendered"].as_s
        error = v["error"].as_s

        it "##{idx}: #{rendered.inspect} rejected (#{error})" do
          expect_raises(Dust::Path::InvalidPathError) { Dust::Path.parse_rendered(rendered) }
        end
      end
    end
  end
end
