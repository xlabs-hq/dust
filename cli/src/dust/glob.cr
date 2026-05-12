require "./path"

module Dust
  module Glob
    # Segment-aware glob matching against `Path` segment arrays.
    #
    # Mirrors `DustProtocol.Glob` from the canonical wire-protocol
    # package.
    #
    # ## Pattern grammar
    #
    # A pattern is a non-empty array of pattern segments. Each segment
    # is either:
    #
    #   - `"*"` — matches exactly one path segment
    #   - `"**"` — matches one or more path segments; **only valid in
    #     the tail position**
    #   - `"\\*"` — matches a path segment that is literally `"*"`
    #   - `"\\**"` — matches a path segment that is literally `"**"`
    #   - any other string — matches that exact path segment
    #
    # Patterns can also be given as rendered slash strings, decoded
    # with the same JSON Pointer escape rules as `Path`.

    class InvalidPatternError < ArgumentError
    end

    enum TokenKind
      Literal
      One
      Many
    end

    record Token, kind : TokenKind, value : String do
      def self.literal(s : String) : Token
        Token.new(TokenKind::Literal, s)
      end

      def self.one : Token
        Token.new(TokenKind::One, "")
      end

      def self.many : Token
        Token.new(TokenKind::Many, "")
      end
    end

    record Compiled, tokens : Array(Token)

    def self.compile(input : String) : Compiled
      compile_segments(Path.parse_rendered(input))
    end

    def self.compile(input : Array(String)) : Compiled
      compile_segments(Path.from_segments(input))
    end

    private def self.compile_segments(segments : Array(String)) : Compiled
      tokens = segments.map { |s| classify_segment(s) }

      # `**` only allowed in tail position
      tokens.each_with_index do |t, i|
        if t.kind == TokenKind::Many && i != tokens.size - 1
          raise InvalidPatternError.new("** is only valid in the tail position of a glob pattern")
        end
      end

      Compiled.new(tokens)
    end

    private def self.classify_segment(seg : String) : Token
      case seg
      when "*"   then Token.one
      when "**"  then Token.many
      when "\\*" then Token.literal("*")
      when "\\**" then Token.literal("**")
      else            Token.literal(seg)
      end
    end

    # Match a (compiled or raw) pattern against a segment-array path.
    def self.match?(pattern : Compiled, path : Array(String)) : Bool
      walk(pattern.tokens, 0, path, 0)
    end

    def self.match?(pattern : String, path : Array(String)) : Bool
      match?(compile(pattern), path)
    end

    def self.match?(pattern : Array(String), path : Array(String)) : Bool
      match?(compile(pattern), path)
    end

    private def self.walk(tokens : Array(Token), ti : Int32, path : Array(String), pi : Int32) : Bool
      # Both exhausted = match
      return true if ti == tokens.size && pi == path.size

      # Tail `**`: match if path has at least one remaining segment
      if ti == tokens.size - 1 && tokens[ti].kind == TokenKind::Many
        return pi < path.size
      end

      return false if ti == tokens.size || pi == path.size

      t = tokens[ti]
      case t.kind
      when TokenKind::One
        walk(tokens, ti + 1, path, pi + 1)
      when TokenKind::Literal
        t.value == path[pi] && walk(tokens, ti + 1, path, pi + 1)
      else
        # Many but not in tail position — caught at compile, defensive only
        false
      end
    end
  end
end
