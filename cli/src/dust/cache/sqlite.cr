require "sqlite3"
require "json"

module Dust
  class Cache
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
