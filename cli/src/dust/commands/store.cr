require "json"

module Dust
  module Commands
    module Store
      def self.create(config : Config, args : Array(String))
        Output.require_auth!(config)

        if args.empty?
          Output.error("Usage: dust create <org/store> [--ttl seconds]")
        end

        store_name = args[0]
        parts = store_name.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end

        ttl : Int64? = nil
        i = 1
        while i < args.size
          if args[i] == "--ttl" && i + 1 < args.size
            ttl = args[i + 1].to_i64
            i += 2
          else
            i += 1
          end
        end

        base_url = derive_http_url(config.server_url)
        body = {} of String => JSON::Any
        body["name"] = JSON::Any.new(parts[1])
        body["ttl"] = JSON::Any.new(ttl) if ttl

        response = HTTP::Client.post(
          "#{base_url}/api/stores",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
            "Content-Type"  => "application/json",
          },
          body: body.to_json
        )

        if response.status_code == 201
          result = JSON.parse(response.body)
          Output.success("Created #{result["full_name"]}")
          expires = result["expires_at"]?
          if expires && !expires.raw.nil?
            puts "Expires: #{expires.as_s}"
          end
        else
          Output.error("Create failed (#{response.status_code}): #{response.body}")
        end
      end

      def self.list(config : Config, args : Array(String))
        Output.require_auth!(config)

        json_output = args.includes?("--json")

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.get(
          "#{base_url}/api/stores",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
          }
        )

        unless response.status.success?
          Output.error("Failed to list stores (#{response.status_code}): #{response.body}")
        end

        result = JSON.parse(response.body)
        stores = result["stores"].as_a

        if json_output
          puts result.to_pretty_json
          return
        end

        if stores.empty?
          puts "No stores. Create one with: dust create <org/store>"
          return
        end

        printf "%-30s %-10s %-20s %-20s\n", "Store", "Status", "Created", "Expires"
        printf "%-30s %-10s %-20s %-20s\n", "-" * 28, "-" * 8, "-" * 18, "-" * 18

        stores.each do |store|
          full_name = store["full_name"].as_s
          status = store["status"].as_s
          created = store["inserted_at"].raw.nil? ? "-" : store["inserted_at"].as_s
          expires = store["expires_at"].raw.nil? ? "-" : store["expires_at"].as_s
          printf "%-30s %-10s %-20s %-20s\n", full_name, status, created, expires
        end
      end

      def self.status(config : Config, args : Array(String))
        if args.empty? || args[0].starts_with?("-")
          show_config_status(config)
          return
        end

        store_name = args[0]
        watch = args.includes?("--watch") || args.includes?("-w")

        Output.require_auth!(config)

        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name)

        conn.on_event do |topic, payload|
          handle_event(cache, store_name, payload)
        end

        begin
          conn.connect_sync
          channel = conn.join(store_name, last_seq)

          sleep 0.3.seconds

          if watch
            run_watch_loop(channel, store_name, config, cache)
          else
            fetch_and_render(channel, store_name, config, cache)
          end
        ensure
          conn.close
          cache.close
        end
      end

      private def self.show_config_status(config : Config)
        puts "Server:    #{config.server_url}"
        puts "Device ID: #{config.device_id}"

        if config.authenticated?
          token = config.token.not_nil!
          visible = token.size > 12 ? token[0..11] + "..." : token
          puts "Auth:      #{visible}"
        else
          puts "Auth:      not authenticated"
        end
      end

      private def self.fetch_and_render(channel : StoreChannel, store_name : String, config : Config, cache : Cache)
        result = channel.push("status", {} of String => JSON::Any)
        status_data = result["response"]

        local_seq = cache.last_seq(store_name)
        render_status(store_name, config, status_data, local_seq)
      end

      private def self.run_watch_loop(channel : StoreChannel, store_name : String, config : Config, cache : Cache)
        Signal::INT.trap { exit 0 }

        loop do
          print "\e[2J\e[H"
          fetch_and_render(channel, store_name, config, cache)
          sleep 2.seconds
        end
      end

      private def self.render_status(store_name : String, config : Config, status : JSON::Any, local_seq : Int64)
        server_seq = status["current_seq"].as_i64
        entry_count = status["entry_count"].as_i64
        op_count = status["op_count"].as_i64
        db_bytes = status["db_size_bytes"].as_i64
        file_bytes = status["file_storage_bytes"].as_i64

        server_display = config.server_url.gsub(/\/ws\/sync$/, "")

        puts "Store:       #{store_name}"
        puts "Connection:  connected (#{server_display})"
        puts "Seq:         #{server_seq} (server) / #{local_seq} (local cache)"
        puts "Entries:     #{format_number(entry_count)}"
        puts "Ops:         #{format_number(op_count)}"

        snap_seq = status["latest_snapshot_seq"]?
        unless snap_seq.nil? || snap_seq.raw.nil?
          snap_at = status["latest_snapshot_at"]?
          at_str = (snap_at && !snap_at.raw.nil?) ? " (#{snap_at.as_s})" : ""
          puts "Compaction:  seq #{snap_seq}#{at_str}"
        end

        puts "Storage:     #{format_bytes(db_bytes)} (sqlite) / #{format_bytes(file_bytes)} (files)"

        expires = status["expires_at"]?
        if expires && !expires.raw.nil?
          puts "Expires:     #{expires.as_s}"
        end

        recent = status["recent_ops"]?.try(&.as_a)
        if recent && !recent.empty?
          puts ""
          puts "Recent ops (last #{recent.size}):"
          recent.each do |op|
            seq = op["store_seq"]
            op_name = op["op"].as_s
            path = op["path"].as_s
            time = op["inserted_at"]?.try(&.as_s) || ""
            printf "  #%-5s %-10s %-30s %s\n", seq, op_name, path, time
          end
        end
      end

      private def self.format_number(n : Int64) : String
        str = n.to_s
        return str if str.size <= 3

        groups = [] of String
        while str.size > 3
          groups.unshift(str[-3..])
          str = str[0...-3]
        end
        groups.unshift(str) unless str.empty?
        groups.join(",")
      end

      private def self.format_bytes(bytes : Int64) : String
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{"%.1f" % (bytes / 1024.0)} KB"
        elsif bytes < 1024 * 1024 * 1024
          "#{"%.1f" % (bytes / (1024.0 * 1024))} MB"
        else
          "#{"%.1f" % (bytes / (1024.0 * 1024 * 1024))} GB"
        end
      end

      private def self.derive_http_url(server_url : String) : String
        uri = URI.parse(server_url)
        scheme = (uri.scheme == "wss") ? "https" : "http"
        port_str = uri.port ? ":#{uri.port}" : ""
        "#{scheme}://#{uri.host}#{port_str}"
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
          type = case value.raw
                 when Int64   then "integer"
                 when Float64 then "float"
                 when String  then "string"
                 when Bool    then "boolean"
                 when Nil     then "null"
                 when Hash    then "map"
                 when Array   then "list"
                 else              "unknown"
                 end
          cache.write(store_name, path, value, type, seq)
        end
      end
    end
  end
end
