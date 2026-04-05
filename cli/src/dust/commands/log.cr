require "json"
require "http/client"

module Dust
  module Commands
    module Log
      # dust log <store> [options]
      def self.log(config : Config, args : Array(String))
        if args.includes?("--help") || args.includes?("-h")
          puts "Usage: dust log <store> [options]"
          puts ""
          puts "Show the audit log for a store."
          puts ""
          puts "Options:"
          puts "  --path <pattern>    Filter by path (supports * and ** wildcards)"
          puts "  --op <type>         Filter by op (set, delete, merge, increment, add, remove, put_file)"
          puts "  --device <id>       Filter by device ID"
          puts "  --since <datetime>  Show ops after ISO8601 timestamp"
          puts "  --limit <n>         Number of entries (default 50)"
          puts "  --page <n>          Page number (default 1)"
          puts "  --json              Output raw JSON"
          return
        end

        Output.require_auth!(config)

        if args.empty? || args[0].starts_with?("-")
          Output.error("Usage: dust log <store> [options]")
        end

        store_name = args[0]
        parts = store_name.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end

        # Parse options
        json_output = false
        query_params = [] of String
        i = 1
        while i < args.size
          case args[i]
          when "--path"
            query_params << "path=#{URI.encode_www_form(args[i + 1])}"
            i += 2
          when "--op"
            query_params << "op=#{URI.encode_www_form(args[i + 1])}"
            i += 2
          when "--device"
            query_params << "device_id=#{URI.encode_www_form(args[i + 1])}"
            i += 2
          when "--since"
            query_params << "since=#{URI.encode_www_form(args[i + 1])}"
            i += 2
          when "--limit"
            query_params << "limit=#{args[i + 1]}"
            i += 2
          when "--page"
            query_params << "page=#{args[i + 1]}"
            i += 2
          when "--json"
            json_output = true
            i += 1
          else
            i += 1
          end
        end

        base_url = derive_http_url(config.server_url)
        url = "#{base_url}/api/stores/#{parts[0]}/#{parts[1]}/log"
        url += "?#{query_params.join("&")}" unless query_params.empty?

        response = HTTP::Client.get(url, headers: HTTP::Headers{
          "Authorization" => "Bearer #{config.token.not_nil!}",
        })

        unless response.status.success?
          Output.error("Failed (#{response.status_code}): #{response.body}")
        end

        result = JSON.parse(response.body)

        if json_output
          puts result.to_pretty_json
          return
        end

        ops = result["ops"].as_a
        pagination = result["pagination"]

        if ops.empty?
          puts "No ops found."
          return
        end

        printf "%-6s %-12s %-30s %-16s %s\n", "Seq", "Op", "Path", "Device", "Time"
        printf "%-6s %-12s %-30s %-16s %s\n", "-" * 4, "-" * 10, "-" * 28, "-" * 14, "-" * 20

        ops.each do |op|
          seq = op["store_seq"]
          op_name = op["op"].as_s
          path = truncate(op["path"].as_s, 28)
          device = truncate(op["device_id"].as_s, 14)
          time = op["inserted_at"]?.try(&.as_s) || "-"
          printf "%-6s %-12s %-30s %-16s %s\n", seq, op_name, path, device, time
        end

        total = pagination["total"].as_i
        page = pagination["page"].as_i
        total_pages = pagination["total_pages"].as_i
        if total_pages > 1
          puts ""
          puts "Page #{page}/#{total_pages} (#{total} total ops)"
        end
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

      private def self.truncate(str : String, max : Int32) : String
        str.size > max ? str[0..max - 4] + "..." : str
      end

      private def self.derive_http_url(server_url : String) : String
        uri = URI.parse(server_url)
        scheme = (uri.scheme == "wss") ? "https" : "http"
        port_str = uri.port ? ":#{uri.port}" : ""
        "#{scheme}://#{uri.host}#{port_str}"
      end
    end
  end
end
