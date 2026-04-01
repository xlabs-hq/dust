require "json"

module Dust
  module Commands
    module Types
      # dust increment <store> <path> [delta]
      def self.increment(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust increment <store> <path> [delta]")

        store, path = args[0], args[1]

        # Default delta is 1; allow negative values via "-- -1" or just "-1"
        delta = if args.size >= 3
                  args[2].to_i64? || args[2].to_f64? || Output.error("Delta must be a number: #{args[2]}")
                else
                  1_i64
                end

        value = case delta
                when Int64   then JSON::Any.new(delta)
                when Float64 then JSON::Any.new(delta)
                else              JSON::Any.new(1_i64) # unreachable
                end

        result = write_op(config, store, "increment", path, value)
        seq = result["response"]["store_seq"]
        Output.success("OK store_seq=#{seq}")
      end

      # dust add <store> <path> <member>
      def self.add(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 3, "dust add <store> <path> <member>")

        store, path, member = args[0], args[1], args[2]
        value = parse_json_or_string(member)

        result = write_op(config, store, "add", path, value)
        seq = result["response"]["store_seq"]
        Output.success("OK store_seq=#{seq}")
      end

      # dust remove <store> <path> <member>
      def self.remove(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 3, "dust remove <store> <path> <member>")

        store, path, member = args[0], args[1], args[2]
        value = parse_json_or_string(member)

        result = write_op(config, store, "remove", path, value)
        seq = result["response"]["store_seq"]
        Output.success("OK store_seq=#{seq}")
      end

      # --- Helpers ---

      private def self.write_op(config : Config, store : String, op : String, path : String, value : JSON::Any) : JSON::Any
        conn = Connection.new(config)
        begin
          conn.connect_sync
          channel = conn.join(store)

          payload = {
            "op"           => JSON::Any.new(op),
            "path"         => JSON::Any.new(path),
            "value"        => value,
            "client_op_id" => JSON::Any.new(Random::Secure.hex(8)),
          } of String => JSON::Any

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

      # Try to parse as JSON first, fall back to plain string.
      private def self.parse_json_or_string(str : String) : JSON::Any
        JSON.parse(str)
      rescue JSON::ParseException
        JSON::Any.new(str)
      end
    end
  end
end
