require "json"

module Dust
  module Commands
    module Data
      # dust put <store> <path> <json> [--if-match N]
      def self.put(config : Config, args : Array(String))
        Output.require_auth!(config)

        positional = [] of String
        if_match : Int64? = nil

        i = 0
        while i < args.size
          case args[i]
          when "--if-match"
            if i + 1 < args.size
              begin
                if_match = args[i + 1].to_i64
              rescue ArgumentError
                Output.error("--if-match requires an integer value")
              end
              i += 2
            else
              Output.error("--if-match requires a value. Usage: dust put <store> <path> <json> [--if-match N]")
              i += 1
            end
          else
            positional << args[i]
            i += 1
          end
        end

        Output.require_args!(positional, 3, "dust put <store> <path> <json> [--if-match N]")

        store, path, json_str = positional[0], positional[1], positional[2]
        value = parse_json(json_str)
        result = write_op(config, store, "set", path, value, if_match: if_match)
        seq = result["response"]["store_seq"]
        Output.success("OK store_seq=#{seq}")
      end

      # dust merge <store> <path> <json>
      def self.merge(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 3, "dust merge <store> <path> <json>")

        store, path, json_str = args[0], args[1], args[2]
        value = parse_json(json_str)
        result = write_op(config, store, "merge", path, value)
        seq = result["response"]["store_seq"]
        Output.success("OK store_seq=#{seq}")
      end

      # dust delete <store> <path>
      def self.delete(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust delete <store> <path>")

        store, path = args[0], args[1]
        result = write_op(config, store, "delete", path, nil)
        seq = result["response"]["store_seq"]
        Output.success("OK store_seq=#{seq}")
      end

      # dust get <store> <path>
      def self.get(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust get <store> <path>")

        store_name, path = args[0], args[1]

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name)

        # Register event handler to populate cache from catch-up
        conn.on_event do |topic, payload|
          handle_event(cache, store_name, payload)
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name, last_seq)

          # Wait for catch-up events to drain into cache
          sleep 0.2.seconds

          value = cache.read(store_name, path)
          if value.nil?
            Output.error("Path '#{path}' not found in store '#{store_name}'.")
          else
            Output.json(value)
          end
        ensure
          conn.close
          cache.close
        end
      end

      # dust entry <store> <path>
      def self.entry(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust entry <store> <path>")

        store_name, path = args[0], args[1]

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name)

        conn.on_event do |topic, payload|
          handle_event(cache, store_name, payload)
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name, last_seq)

          # Wait for catch-up events to drain into cache
          sleep 0.2.seconds

          result = cache.read_entry(store_name, path)
          if result.nil?
            STDERR.puts %({"error":"not_found"})
            exit 1
          else
            Output.json({
              "path"     => JSON::Any.new(path),
              "value"    => result[:value],
              "type"     => JSON::Any.new(result[:type]),
              "revision" => JSON::Any.new(result[:seq]),
            })
          end
        ensure
          conn.close
          cache.close
        end
      end

      # dust enum <store> <pattern> [--limit N] [--after C] [--order asc|desc] [--select entries|keys|prefixes]
      def self.enum(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust enum <store> <pattern> [--limit N] [--after C] [--order asc|desc] [--select entries|keys|prefixes]")

        store_name, pattern = args[0], args[1]
        flag_args = args[2..]
        flags = parse_flags(flag_args)

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name)

        conn.on_event do |topic, payload|
          handle_event(cache, store_name, payload)
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name, last_seq)

          # Wait for catch-up events to drain
          sleep 0.2.seconds

          if flags.empty?
            # Flagless backwards-compat behavior: {path => value} map.
            entries = cache.read_all(store_name)
            matched = entries.select { |path, _| Glob.match?(pattern, path) }

            result = JSON::Any.new(
              matched.map { |path, value|
                {path, value}
              }.to_h
            )
            Output.json(result)
          else
            # Paginated browse path.
            limit = (flags["limit"]? || "50").to_i
            after = flags["after"]?
            order = flags["order"]? || "asc"
            select_flag = flags["select"]? || "entries"

            begin
              items, next_cursor = cache.browse(
                store_name,
                pattern: pattern,
                limit: limit,
                after: after,
                order: order,
                select_as: select_flag,
              )

              Output.json({
                "items"       => render_browse_items(items, select_flag),
                "next_cursor" => next_cursor,
              })
            rescue ex : ArgumentError
              Output.error(ex.message || "invalid argument")
            end
          end
        ensure
          conn.close
          cache.close
        end
      end

      # dust get-many <store> <path>...
      def self.get_many(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 1, "dust get-many <store> <path> [<path>...]")

        store_name = args[0]
        paths = args[1..]

        if paths.empty?
          Output.json({
            "entries" => {} of String => JSON::Any,
            "missing" => [] of String,
          })
          return
        end

        if paths.size > 1000
          Output.error("maximum 1000 paths per call")
          return
        end

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name)

        conn.on_event do |topic, payload|
          handle_event(cache, store_name, payload)
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name, last_seq)

          # Wait for catch-up events to drain into cache
          sleep 0.2.seconds

          result = cache.read_many(store_name, paths)
          found = result.transform_values { |v| v[:value] }
          missing = paths.uniq - found.keys

          Output.json({
            "entries" => found,
            "missing" => missing,
          })
        ensure
          conn.close
          cache.close
        end
      end

      # dust range <store> <from> <to> [--limit N] [--after C] [--order asc|desc] [--select entries|keys]
      def self.range(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 3, "dust range <store> <from> <to> [--limit N] [--after C] [--order asc|desc] [--select entries|keys]")

        store_name, from, to = args[0], args[1], args[2]
        flag_args = args[3..]
        flags = parse_flags(flag_args)

        limit = (flags["limit"]? || "50").to_i
        after = flags["after"]?
        order = flags["order"]? || "asc"
        select_flag = flags["select"]? || "entries"

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name)

        conn.on_event do |topic, payload|
          handle_event(cache, store_name, payload)
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name, last_seq)

          # Wait for catch-up events to drain
          sleep 0.2.seconds

          begin
            items, next_cursor = cache.browse(
              store_name,
              from: from,
              to: to,
              limit: limit,
              after: after,
              order: order,
              select_as: select_flag,
            )

            Output.json({
              "items"       => render_browse_items(items, select_flag),
              "next_cursor" => next_cursor,
            })
          rescue ex : ArgumentError
            Output.error(ex.message || "invalid argument")
          end
        ensure
          conn.close
          cache.close
        end
      end

      # --- Helpers ---

      # Walks args and extracts `--name value` pairs into a hash.
      # Reused by enum/range/get-many flag parsing.
      private def self.parse_flags(args : Array(String)) : Hash(String, String)
        flags = {} of String => String
        i = 0
        while i < args.size
          arg = args[i]
          if arg.starts_with?("--")
            name = arg[2..]
            i += 1
            Output.error("missing value for --#{name}") if i >= args.size
            flags[name] = args[i]
          end
          i += 1
        end
        flags
      end

      # Renders browse results for JSON output. Entries become objects with
      # path/value/type/revision; keys/prefixes pass through as string arrays.
      private def self.render_browse_items(items : Array(Cache::BrowseEntry) | Array(String), select_flag : String)
        case select_flag
        when "keys", "prefixes"
          items.as(Array(String))
        else
          items.as(Array(Cache::BrowseEntry)).map do |row|
            {
              "path"     => JSON::Any.new(row[:path]),
              "value"    => row[:value],
              "type"     => JSON::Any.new(row[:type]),
              "revision" => JSON::Any.new(row[:seq]),
            }
          end
        end
      end

      private def self.write_op(config : Config, store : String, op : String, path : String, value : JSON::Any?, if_match : Int64? = nil) : JSON::Any
        conn = Connection.new(config)
        begin
          conn.connect_sync
          channel = conn.join(store)

          payload = {
            "op"           => JSON::Any.new(op),
            "path"         => JSON::Any.new(path),
            "client_op_id" => JSON::Any.new(Random::Secure.hex(8)),
          } of String => JSON::Any

          if value
            payload["value"] = value
          end

          if im = if_match
            payload["if_match"] = JSON::Any.new(im)
          end

          result = channel.push("write", payload)

          status = result["status"].as_s
          unless status == "ok"
            reason = result["response"]?.try(&.["reason"]?.try(&.as_s)) || "unknown error"
            if reason == "conflict"
              STDERR.puts %({"error":"conflict"})
              exit 1
            end
            Output.error("Write failed: #{reason}")
          end

          result
        ensure
          conn.close
        end
      end

      private def self.parse_json(str : String) : JSON::Any
        JSON.parse(str)
      rescue ex : JSON::ParseException
        Output.error("Invalid JSON: #{ex.message}")
        # Output.error calls exit, but the compiler doesn't know that.
        # This line is unreachable but satisfies the type checker.
        raise ex
      end

      private def self.handle_event(cache : Cache, store_name : String, payload : JSON::Any)
        op = payload["op"]?.try(&.as_s)
        path = payload["path"]?.try(&.as_s)
        seq = payload["store_seq"]?.try(&.as_i64)

        return unless op && path && seq

        case op
        when "delete"
          cache.delete(store_name, path)
        else
          value = payload["value"]?
          return unless value
          type = infer_type(value)
          cache.write(store_name, path, value, type, seq)
        end
      end

      private def self.infer_type(value : JSON::Any) : String
        case value.raw
        when Int64   then "integer"
        when Float64 then "float"
        when String  then "string"
        when Bool    then "boolean"
        when Nil     then "null"
        when Hash    then "map"
        when Array   then "list"
        else              "unknown"
        end
      end
    end
  end
end
