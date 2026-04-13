require "sqlite3"
require "json"
require "../glob"

module Dust
  class Cache
    alias BrowseEntry = NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64)
    alias BrowseResult = Tuple(Array(BrowseEntry) | Array(String), String?)
    @db : DB::Database

    def initialize(path : String? = nil)
      db_path = path || File.join(Config::DATA_DIR, "cache.db")
      if db_path != ":memory:"
        Dir.mkdir_p(File.dirname(db_path))
      end
      uri = URI.new(scheme: "sqlite3", host: nil, path: db_path)
      @db = DB.open(uri)
      migrate
    end

    def read(store : String, path : String) : JSON::Any?
      @db.query_one?(
        "SELECT value FROM dust_cache WHERE store = ? AND path = ? AND path != ?",
        store, path, "_dust:last_seq"
      ) do |rs|
        JSON.parse(rs.read(String))
      end
    end

    def read_entry(store : String, path : String) : NamedTuple(value: JSON::Any, type: String, seq: Int64)?
      @db.query_one?(
        "SELECT value, type, seq FROM dust_cache WHERE store = ? AND path = ? AND path != ?",
        store, path, "_dust:last_seq"
      ) do |rs|
        value = JSON.parse(rs.read(String))
        type_str = rs.read(String)
        seq = rs.read(Int64)
        {value: value, type: type_str, seq: seq}
      end
    end

    def read_many(store : String, paths : Array(String)) : Hash(String, NamedTuple(value: JSON::Any, type: String, seq: Int64))
      result = {} of String => NamedTuple(value: JSON::Any, type: String, seq: Int64)
      unique = paths.uniq
      return result if unique.empty?

      placeholders = Array.new(unique.size, "?").join(", ")
      sql = "SELECT path, value, type, seq FROM dust_cache WHERE store = ? AND path IN (#{placeholders}) AND path != ?"
      args = [store] of DB::Any
      unique.each { |p| args << p }
      args << "_dust:last_seq"

      @db.query(sql, args: args) do |rs|
        rs.each do
          path = rs.read(String)
          value = JSON.parse(rs.read(String))
          type_str = rs.read(String)
          seq = rs.read(Int64)
          result[path] = {value: value, type: type_str, seq: seq}
        end
      end
      result
    end

    def read_all(store : String) : Array(Tuple(String, JSON::Any))
      results = [] of Tuple(String, JSON::Any)
      @db.query(
        "SELECT path, value FROM dust_cache WHERE store = ? AND path != ?",
        store, "_dust:last_seq"
      ) do |rs|
        rs.each do
          path = rs.read(String)
          value = JSON.parse(rs.read(String))
          results << {path, value}
        end
      end
      results
    end

    def write(store : String, path : String, value : JSON::Any, type : String, seq : Int64)
      @db.exec(
        "INSERT INTO dust_cache (store, path, value, type, seq) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(store, path) DO UPDATE SET value = excluded.value, type = excluded.type, seq = excluded.seq",
        store, path, value.to_json, type, seq
      )
      update_seq_sentinel(store, seq)
    end

    def delete(store : String, path : String)
      @db.exec("DELETE FROM dust_cache WHERE store = ? AND path = ?", store, path)
    end

    def last_seq(store : String) : Int64
      @db.query_one?(
        "SELECT seq FROM dust_cache WHERE store = ? AND path = ?",
        store, "_dust:last_seq"
      ) do |rs|
        rs.read(Int64)
      end || 0_i64
    end

    def browse(
      store : String,
      pattern : String = "**",
      limit : Int32 = 50,
      after : String? = nil,
      order : String = "asc",
      select_as : String = "entries",
      from : String? = nil,
      to : String? = nil,
    ) : BrowseResult
      if from && to
        if select_as == "prefixes"
          raise ArgumentError.new("select_as: prefixes not supported for from/to range queries")
        end

        rows = fetch_range_rows(store, from, to, after, order, limit + 1)
        page = rows.first(limit)
        next_cursor =
          if rows.size > limit && !page.empty?
            page.last[:path]
          else
            nil
          end

        projected = project_page(page, select_as, pattern)
        return {projected, next_cursor}
      end

      validate_select_pattern!(select_as, pattern)

      literal_prefix = literal_prefix_of(pattern)
      rows = fetch_rows(store, literal_prefix, after, order, limit + 1)

      matched = rows.select { |row| Glob.match?(pattern, row[:path]) }
      page = matched.first(limit)

      next_cursor =
        if matched.size > limit && !page.empty?
          page.last[:path]
        else
          nil
        end

      projected = project_page(page, select_as, pattern)
      {projected, next_cursor}
    end

    def close
      @db.close
    end

    private def migrate
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS dust_cache (
          store TEXT NOT NULL,
          path TEXT NOT NULL,
          value TEXT NOT NULL,
          type TEXT NOT NULL,
          seq INTEGER NOT NULL,
          PRIMARY KEY (store, path)
        )
      SQL
    end

    # NOTE: Known limitation — this fetches `limit + 1` raw rows via LIKE prefix
    # and post-filters by glob. Narrow globs (e.g. "a.*.b") over wide prefixes
    # can silently drop matches past the raw window. Matches the pre-Phase-1-C1
    # state of the Elixir Ecto cache; a chunked-walk fix is deferred as follow-up.
    private def fetch_rows(
      store : String,
      literal_prefix : String?,
      after : String?,
      order : String,
      limit : Int32,
    ) : Array(BrowseEntry)
      where_clauses = ["store = ?"]
      args = [store] of DB::Any

      if literal_prefix && !literal_prefix.empty?
        where_clauses << "path LIKE ? ESCAPE '\\'"
        args << escape_like(literal_prefix) + "%"
      end

      if after
        where_clauses << (order == "asc" ? "path > ?" : "path < ?")
        args << after
      end

      where_clauses << "path != '_dust:last_seq'"

      direction = order == "desc" ? "DESC" : "ASC"
      sql = "SELECT path, value, type, seq FROM dust_cache WHERE #{where_clauses.join(" AND ")} ORDER BY path #{direction} LIMIT ?"
      args << limit

      rows = [] of BrowseEntry
      @db.query(sql, args: args) do |rs|
        rs.each do
          path = rs.read(String)
          value = JSON.parse(rs.read(String))
          type_str = rs.read(String)
          seq = rs.read(Int64)
          rows << {path: path, value: value, type: type_str, seq: seq}
        end
      end
      rows
    end

    private def fetch_range_rows(
      store : String,
      from : String,
      to : String,
      after : String?,
      order : String,
      limit : Int32,
    ) : Array(BrowseEntry)
      where_clauses = ["store = ?", "path >= ?", "path < ?"]
      args = [store, from, to] of DB::Any

      if after
        where_clauses << (order == "desc" ? "path < ?" : "path > ?")
        args << after
      end

      where_clauses << "path != '_dust:last_seq'"

      direction = order == "desc" ? "DESC" : "ASC"
      sql = "SELECT path, value, type, seq FROM dust_cache WHERE #{where_clauses.join(" AND ")} ORDER BY path #{direction} LIMIT ?"
      args << limit

      rows = [] of BrowseEntry
      @db.query(sql, args: args) do |rs|
        rs.each do
          path = rs.read(String)
          value = JSON.parse(rs.read(String))
          type_str = rs.read(String)
          seq = rs.read(Int64)
          rows << {path: path, value: value, type: type_str, seq: seq}
        end
      end
      rows
    end

    private def literal_prefix_of(pattern : String) : String?
      return "" if pattern == "**"
      segments = pattern.split('.')
      literal = [] of String
      segments.each do |seg|
        break if seg.includes?('*')
        literal << seg
      end
      literal.empty? ? nil : literal.join('.')
    end

    private def escape_like(s : String) : String
      s.gsub("\\", "\\\\").gsub("%", "\\%").gsub("_", "\\_")
    end

    private def validate_select_pattern!(select_as : String, pattern : String)
      if select_as == "prefixes" && pattern != "**" && !pattern.ends_with?(".**")
        raise ArgumentError.new("select: prefixes requires pattern ending in .** or being ** (got #{pattern})")
      end
    end

    private def project_page(
      page : Array(BrowseEntry),
      select_as : String,
      pattern : String,
    ) : Array(BrowseEntry) | Array(String)
      case select_as
      when "entries"
        page
      when "keys"
        page.map { |row| row[:path] }
      when "prefixes"
        prefixes_of(page, pattern)
      else
        raise ArgumentError.new("invalid select: #{select_as}")
      end
    end

    private def prefixes_of(page : Array(BrowseEntry), pattern : String) : Array(String)
      literal = literal_prefix_of_for_prefixes(pattern)
      extracted = [] of String
      page.each do |row|
        if prefix = extract_prefix(row[:path], literal)
          extracted << prefix
        end
      end
      extracted.uniq.sort
    end

    private def literal_prefix_of_for_prefixes(pattern : String) : String
      return "" if pattern == "**"
      pattern.sub(/\.\*\*$/, "")
    end

    private def extract_prefix(path : String, literal : String) : String?
      if literal.empty?
        segments = path.split('.', 2)
        segments.first?
      else
        prefix_dot = literal + "."
        return nil unless path.starts_with?(prefix_dot)
        rest = path[prefix_dot.size..]
        next_seg = rest.split('.', 2).first
        "#{literal}.#{next_seg}"
      end
    end

    private def update_seq_sentinel(store : String, seq : Int64)
      @db.exec(
        "INSERT INTO dust_cache (store, path, value, type, seq) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(store, path) DO UPDATE SET seq = excluded.seq, value = excluded.value
         WHERE excluded.seq > dust_cache.seq",
        store, "_dust:last_seq", seq.to_json, "integer", seq
      )
    end
  end
end
