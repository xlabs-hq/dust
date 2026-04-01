module Dust
  module Commands
    module Log
      # dust log <store> [options]
      #
      # The audit log lives server-side and requires a REST API endpoint.
      # For now, direct users to the web dashboard.
      def self.log(config : Config, args : Array(String))
        puts "The `dust log` command requires the web dashboard or REST API."
        puts ""
        puts "View your audit log at:"
        puts "  #{derive_http_url(config.server_url)}/dashboard/audit-log"
        puts ""
        puts "This command will be fully implemented when REST API endpoints"
        puts "are added to the server."
      end

      # dust rollback <store> <path> --to-seq <n>
      # dust rollback <store> --to-seq <n>
      def self.rollback(config : Config, args : Array(String))
        # Handle --help before auth check
        if args.includes?("--help") || args.includes?("-h")
          puts "Usage: dust rollback <store> [path] --to-seq <n>"
          puts ""
          puts "Rollback a path or entire store to a previous sequence number."
          puts ""
          puts "Examples:"
          puts "  dust rollback myorg/mystore users.alice --to-seq 5"
          puts "  dust rollback myorg/mystore --to-seq 3"
          return
        end

        Output.require_auth!(config)

        # Parse args: positional + required --to-seq flag
        to_seq : Int64? = nil
        positional = [] of String

        i = 0
        while i < args.size
          case args[i]
          when "--to-seq"
            if i + 1 < args.size
              to_seq = args[i + 1].to_i64?
              unless to_seq
                Output.error("--to-seq requires an integer value.")
              end
              i += 2
            else
              Output.error("--to-seq requires a value. Usage: dust rollback <store> [path] --to-seq <n>")
              i += 1
            end
          else
            positional << args[i]
            i += 1
          end
        end

        if positional.empty?
          Output.error("Usage: dust rollback <store> [path] --to-seq <n>")
        end

        unless to_seq
          Output.error("--to-seq is required. Usage: dust rollback <store> [path] --to-seq <n>")
        end

        store = positional[0]
        path = positional[1]?

        conn = Connection.new(config)
        begin
          conn.connect_sync
          channel = conn.join(store)

          payload = {} of String => JSON::Any
          payload["to_seq"] = JSON::Any.new(to_seq.not_nil!)

          if path
            payload["path"] = JSON::Any.new(path)
          end

          result = channel.push("rollback", payload)

          status = result["status"].as_s
          unless status == "ok"
            reason = result["response"]?.try(&.["reason"]?.try(&.as_s)) || "unknown error"
            Output.error("Rollback failed: #{reason}")
          end

          response = result["response"]

          if path
            if response["noop"]?.try(&.as_bool)
              Output.success("No changes needed (already at or before seq #{to_seq}).")
            else
              seq = response["store_seq"]
              Output.success("OK rolled back '#{path}' to seq #{to_seq}, new store_seq=#{seq}")
            end
          else
            ops_written = response["ops_written"]
            Output.success("OK store rollback to seq #{to_seq}, #{ops_written} ops written")
          end
        ensure
          conn.close
        end
      end

      # --- Helpers ---

      private def self.derive_http_url(server_url : String) : String
        uri = URI.parse(server_url)
        scheme = (uri.scheme == "wss") ? "https" : "http"
        port_str = uri.port ? ":#{uri.port}" : ""
        "#{scheme}://#{uri.host}#{port_str}"
      end
    end
  end
end
