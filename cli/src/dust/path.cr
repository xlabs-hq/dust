module Dust
  # Segment-first paths for the Dust CLI.
  #
  # A path is a non-empty array of non-empty string segments:
  #
  #     ["posts", "hello.world", "image/file"]
  #
  # Public CLI helpers accept either a segment array or a canonical
  # rendered slash string (see `from_input`). Internally segments are
  # the authoritative form; strings are rendered at boundaries (CLI
  # args, SQLite keys, wire format).
  #
  # Mirrors `DustProtocol.Path` from the canonical protocol package.
  #
  # ## Rendering
  #
  # Canonical rendered paths join segments with `/` and escape per RFC
  # 6901 (JSON Pointer) inside each segment:
  #
  #     `~` -> `~0`
  #     `/` -> `~1`
  #
  # `.` has no special meaning — `"example.com"` is one segment.
  module Path
    class InvalidPathError < ArgumentError
    end

    # ----------------------------------------------------------------
    # Validation
    # ----------------------------------------------------------------

    def self.from_segments(segments : Array(String)) : Array(String)
      raise InvalidPathError.new("path is empty") if segments.empty?

      segments.each do |s|
        raise InvalidPathError.new("segment is empty") if s.empty?
      end

      segments
    end

    # ----------------------------------------------------------------
    # Rendering: segments -> rendered string
    # ----------------------------------------------------------------

    # `~` must be escaped first or the `/` -> `~1` substitution would
    # create false `~1` sequences in subsequent decoding.
    def self.render(segments : Array(String)) : String
      from_segments(segments)
      segments.map { |s| escape_segment(s) }.join('/')
    end

    private def self.escape_segment(seg : String) : String
      seg.gsub('~', "~0").gsub('/', "~1")
    end

    # ----------------------------------------------------------------
    # Parsing: rendered string -> segments
    # ----------------------------------------------------------------

    def self.parse_rendered(s : String) : Array(String)
      raise InvalidPathError.new("path is empty") if s.empty?

      parts = s.split('/')
      parts.each do |p|
        if p.empty?
          raise InvalidPathError.new("path \"#{s}\" contains empty segments")
        end
      end

      parts.map { |p| unescape_segment(p) }
    end

    # Walks the segment once, treating `~` as the start of a two-char
    # escape. Anything else after `~` is rejected.
    private def self.unescape_segment(seg : String) : String
      out = String::Builder.new
      i = 0
      while i < seg.size
        ch = seg[i]
        if ch == '~'
          next_ch = (i + 1 < seg.size) ? seg[i + 1] : nil

          case next_ch
          when '0'
            out << '~'
            i += 2
          when '1'
            out << '/'
            i += 2
          else
            raise InvalidPathError.new("invalid escape in segment #{seg.inspect}")
          end
        else
          out << ch
          i += 1
        end
      end
      out.to_s
    end

    # ----------------------------------------------------------------
    # Normalize
    # ----------------------------------------------------------------

    def self.normalize_rendered(s : String) : String
      render(parse_rendered(s))
    end

    # ----------------------------------------------------------------
    # Boundary input — accept string or segment array
    # ----------------------------------------------------------------

    # Note: Crystal doesn't have union types at the call site as nicely
    # as TS, so we expose two overloads instead.
    def self.from_input(s : String) : Array(String)
      parse_rendered(s)
    end

    def self.from_input(segs : Array(String)) : Array(String)
      from_segments(segs)
    end

    # ----------------------------------------------------------------
    # Composition
    # ----------------------------------------------------------------

    def self.child(parent : Array(String), segment : String) : Array(String)
      from_segments(parent)
      raise InvalidPathError.new("child segment is empty") if segment.empty?
      parent + [segment]
    end

    def self.concat(parent : Array(String), tail : Array(String)) : Array(String)
      from_segments(parent)
      from_segments(tail)
      parent + tail
    end

    def self.ancestor?(ancestor : Array(String), descendant : Array(String)) : Bool
      return false if ancestor.size >= descendant.size
      ancestor.each_with_index do |a, i|
        return false if a != descendant[i]
      end
      true
    end

    def self.render_descendant_prefix(segments : Array(String)) : String
      render(segments) + '/'
    end

    # ----------------------------------------------------------------
    # Legacy compatibility helpers (transitional). Used by the CLI to
    # accept dotted-string arguments during the migration window.
    # Removed once the CLI exclusively uses slash-rendered or
    # segment-array inputs.
    # ----------------------------------------------------------------

    def self.parse_legacy_dotted(s : String) : Array(String)
      raise InvalidPathError.new("path is empty") if s.empty?
      parts = s.split('.')
      parts.each do |p|
        if p.empty?
          raise InvalidPathError.new("legacy path \"#{s}\" contains empty segments")
        end
      end
      parts
    end

    # Heuristic: a string containing `/` is canonical (re-validated);
    # otherwise it's dot-split and re-rendered to slash form.
    def self.normalize_path(s : String) : String
      if s.includes?('/')
        normalize_rendered(s)
      else
        render(parse_legacy_dotted(s))
      end
    end

    # Wildcards `*` / `**` survive. Same heuristic as normalize_path.
    def self.normalize_pattern(s : String) : String
      return "**" if s == "**"
      if s.includes?('/')
        parts = s.split('/')
        parts.each do |p|
          if p.empty?
            raise InvalidPathError.new("pattern \"#{s}\" contains empty segments")
          end
        end
        s
      else
        parts = s.split('.')
        parts.each do |p|
          if p.empty?
            raise InvalidPathError.new("pattern \"#{s}\" contains empty segments")
          end
        end
        parts.join('/')
      end
    end
  end
end
