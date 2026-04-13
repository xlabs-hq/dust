require "json"

module Dust
  module Commands
    module Data
      # dust put <store> <path> <json>
      def self.put(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 3, "dust put <store> <path> <json>")

        store, path, json_str = args[0], args[1], args[2]
        value = parse_json(json_str)
        result = write_op(config, store, "set", path, value)
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

      # dust enum <store> <pattern>
      def self.enum(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust enum <store> <pattern>")

        store_name, pattern = args[0], args[1]

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

          entries = cache.read_all(store_name)

          matched = entries.select { |path, _| Glob.match?(pattern, path) }

          result = JSON::Any.new(
            matched.map { |path, value|
              {path, value}
            }.to_h
          )
          Output.json(result)
        ensure
          conn.close
          cache.close
        end
      end

      # --- Helpers ---

      private def self.write_op(config : Config, store : String, op : String, path : String, value : JSON::Any?) : JSON::Any
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

          result = channel.push("write", payload)

          status = result["status"].as_s
          unless status == "ok"
            reason = result["response"]?.try(&.["reason"]?.try(&.as_s)) || "unknown error"
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
