module Dust
  module Glob
    # Match a glob pattern against a dot-separated path.
    #
    # Pattern syntax:
    #   - `*`  matches exactly one path segment
    #   - `**` matches one or more path segments
    #   - Exact segments match literally
    #
    # Examples:
    #   Glob.match?("posts.*", "posts.hello")       # => true
    #   Glob.match?("posts.**", "posts.a.b")         # => true
    #   Glob.match?("posts.**", "posts")             # => false (** needs 1+)
    def self.match?(pattern : String, path : String) : Bool
      match_segments(pattern.split("."), path.split("."))
    end

    private def self.match_segments(pattern : Array(String), path : Array(String)) : Bool
      # Both exhausted — match
      return true if pattern.empty? && path.empty?

      # One exhausted, other not — no match
      return false if pattern.empty? || path.empty?

      head = pattern[0]
      rest = pattern[1..]

      case head
      when "**"
        # ** matches one or more segments
        if rest.empty?
          # trailing ** matches any remaining segments (1+)
          return path.size >= 1
        end

        # Try: consume one path segment and keep ** for more,
        # or consume one path segment and move past **
        path_rest = path[1..]
        match_segments(rest, path_rest) || match_segments(pattern, path_rest)
      when "*"
        # * matches exactly one segment
        match_segments(rest, path[1..])
      else
        # Literal segment match
        if head == path[0]
          match_segments(rest, path[1..])
        else
          false
        end
      end
    end
  end
end
