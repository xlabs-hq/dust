require "./spec_helper"
require "../src/dust/glob"
require "../src/dust/path"
require "json"

describe Dust::Glob do
  describe ".compile" do
    it "compiles a segment array" do
      Dust::Glob.compile(["posts", "*"]).should be_a(Dust::Glob::Compiled)
    end

    it "compiles a rendered slash string" do
      Dust::Glob.compile("posts/*").should be_a(Dust::Glob::Compiled)
    end

    it "rejects empty pattern" do
      expect_raises(Dust::Path::InvalidPathError) { Dust::Glob.compile("") }
      expect_raises(Dust::Path::InvalidPathError) { Dust::Glob.compile([] of String) }
    end

    it "rejects ** in non-tail position" do
      expect_raises(Dust::Glob::InvalidPatternError) { Dust::Glob.compile(["a", "**", "b"]) }
      expect_raises(Dust::Glob::InvalidPatternError) { Dust::Glob.compile("a/**/b") }
    end

    it "accepts ** in tail position" do
      Dust::Glob.compile(["a", "**"]).should be_a(Dust::Glob::Compiled)
      Dust::Glob.compile("a/**").should be_a(Dust::Glob::Compiled)
    end
  end

  describe ".match? — wildcards" do
    it "* matches exactly one segment" do
      Dust::Glob.match?(["posts", "*"], ["posts", "hello"]).should be_true
      Dust::Glob.match?(["posts", "*"], ["posts"]).should be_false
      Dust::Glob.match?(["posts", "*"], ["posts", "hello", "title"]).should be_false
    end

    it "tail ** matches one-or-more segments" do
      Dust::Glob.match?(["posts", "**"], ["posts", "a"]).should be_true
      Dust::Glob.match?(["posts", "**"], ["posts", "a", "b", "c"]).should be_true
      Dust::Glob.match?(["posts", "**"], ["posts"]).should be_false
    end

    it "literal segments match exactly" do
      Dust::Glob.match?(["a", "b", "c"], ["a", "b", "c"]).should be_true
      Dust::Glob.match?(["a", "b", "c"], ["a", "b", "d"]).should be_false
    end

    it "* mid-pattern" do
      Dust::Glob.match?(["a", "*", "c"], ["a", "b", "c"]).should be_true
      Dust::Glob.match?(["a", "*", "c"], ["a", "b", "d"]).should be_false
    end
  end

  describe ".match? — literal characters" do
    it "dots are literal" do
      Dust::Glob.match?(["hello.world"], ["hello.world"]).should be_true
      Dust::Glob.match?(["hello.world"], ["hello", "world"]).should be_false
    end

    it "rendered string with escapes round-trips" do
      Dust::Glob.match?("files/image~1file", ["files", "image/file"]).should be_true
      Dust::Glob.match?("a~0b", ["a~b"]).should be_true
    end
  end

  describe ".match? — literal-wildcard escapes" do
    it "\\* matches literal asterisk segment" do
      Dust::Glob.match?(["a", "\\*"], ["a", "*"]).should be_true
      Dust::Glob.match?(["a", "\\*"], ["a", "x"]).should be_false
    end

    it "\\** matches literal double-asterisk segment" do
      Dust::Glob.match?(["a", "\\**"], ["a", "**"]).should be_true
      Dust::Glob.match?(["a", "\\**"], ["a", "x", "y"]).should be_false
    end
  end

  # --------------------------------------------------------------------
  # Fixture-driven conformance.
  # --------------------------------------------------------------------

  describe "fixture conformance (protocol/spec/fixtures/glob_vectors.json)" do
    fixture_path = File.expand_path("../../protocol/spec/fixtures/glob_vectors.json", __DIR__)
    vectors = JSON.parse(File.read(fixture_path)).as_a

    vectors.each_with_index do |raw, idx|
      v = raw.as_h
      valid = v["valid"].as_bool

      if valid
        pattern_segments = v["pattern_segments"].as_a.map(&.as_s)
        pattern_rendered = v["pattern_rendered"].as_s
        path = v["path"].as_a.map(&.as_s)
        expected = v["match"].as_bool

        it "##{idx}: #{pattern_segments.inspect} vs #{path.inspect} -> #{expected}" do
          Dust::Glob.match?(pattern_segments, path).should eq expected
          Dust::Glob.match?(pattern_rendered, path).should eq expected
        end
      else
        pattern_rendered = v["pattern_rendered"].as_s

        it "##{idx}: pattern #{pattern_rendered.inspect} rejected" do
          expect_raises(Exception) { Dust::Glob.compile(pattern_rendered) }
        end
      end
    end
  end
end
