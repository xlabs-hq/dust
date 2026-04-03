require "json"
require "http/client"

module Dust
  module Commands
    module Webhook
      def self.webhook(config : Config, args : Array(String))
        if args.empty?
          Output.error("Usage: dust webhook <create|list|delete|ping|deliveries> <store> [args]")
        end

        subcommand = args[0]
        rest = args[1..]

        case subcommand
        when "create"     then create(config, rest)
        when "list"       then list(config, rest)
        when "delete"     then delete_webhook(config, rest)
        when "ping"       then ping(config, rest)
        when "deliveries" then deliveries(config, rest)
        else
          Output.error("Unknown webhook subcommand: #{subcommand}")
        end
      end

      # dust webhook create org/store https://example.com/hook
      def self.create(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust webhook create <store> <url>")

        store_name, url = args[0], args[1]
        org, store = parse_store_name(store_name)

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.post(
          "#{base_url}/api/stores/#{org}/#{store}/webhooks",
          headers: auth_headers(config, "application/json"),
          body: {"url" => url}.to_json
        )

        if response.status_code == 201
          result = JSON.parse(response.body)
          puts ""
          puts "Webhook created."
          puts ""
          puts "  ID:     #{result["id"]}"
          puts "  URL:    #{result["url"]}"
          puts "  Secret: #{result["secret"]}"
          puts ""
          puts "Save this secret now -- it will not be shown again."
          puts ""
        else
          Output.error("Create failed (#{response.status_code}): #{response.body}")
        end
      end

      # dust webhook list org/store
      def self.list(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 1, "dust webhook list <store>")

        store_name = args[0]
        org, store = parse_store_name(store_name)

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.get(
          "#{base_url}/api/stores/#{org}/#{store}/webhooks",
          headers: auth_headers(config)
        )

        if response.status.success?
          result = JSON.parse(response.body)
          webhooks = result["webhooks"].as_a

          if webhooks.empty?
            puts "No webhooks configured."
          else
            printf "%-38s %-40s %-8s %-6s %-6s\n", "ID", "URL", "Active", "Seq", "Fails"
            printf "%-38s %-40s %-8s %-6s %-6s\n", "-" * 36, "-" * 38, "-" * 6, "-" * 4, "-" * 5
            webhooks.each do |wh|
              active = wh["active"].as_bool ? "yes" : "no"
              printf "%-38s %-40s %-8s %-6s %-6s\n",
                wh["id"].as_s[0..35],
                truncate(wh["url"].as_s, 38),
                active,
                wh["last_delivered_seq"],
                wh["failure_count"]
            end
          end
        else
          Output.error("List failed (#{response.status_code}): #{response.body}")
        end
      end

      # dust webhook delete org/store <id>
      def self.delete_webhook(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust webhook delete <store> <id>")

        store_name, webhook_id = args[0], args[1]
        org, store = parse_store_name(store_name)

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.delete(
          "#{base_url}/api/stores/#{org}/#{store}/webhooks/#{webhook_id}",
          headers: auth_headers(config)
        )

        if response.status.success?
          Output.success("Webhook deleted.")
        else
          Output.error("Delete failed (#{response.status_code}): #{response.body}")
        end
      end

      # dust webhook ping org/store <id>
      def self.ping(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust webhook ping <store> <id>")

        store_name, webhook_id = args[0], args[1]
        org, store = parse_store_name(store_name)

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.post(
          "#{base_url}/api/stores/#{org}/#{store}/webhooks/#{webhook_id}/ping",
          headers: auth_headers(config),
          body: ""
        )

        if response.status.success?
          result = JSON.parse(response.body)
          status = result["status_code"]
          ms = result["response_ms"]
          puts "Ping OK -- target returned #{status} in #{ms}ms"
        else
          Output.error("Ping failed (#{response.status_code}): #{response.body}")
        end
      end

      # dust webhook deliveries org/store <id> [--limit N]
      def self.deliveries(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust webhook deliveries <store> <id> [--limit N]")

        store_name, webhook_id = args[0], args[1]
        org, store = parse_store_name(store_name)
        limit = 20

        i = 2
        while i < args.size
          if args[i] == "--limit" && i + 1 < args.size
            limit = args[i + 1].to_i
            i += 2
          else
            i += 1
          end
        end

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.get(
          "#{base_url}/api/stores/#{org}/#{store}/webhooks/#{webhook_id}/deliveries?limit=#{limit}",
          headers: auth_headers(config)
        )

        if response.status.success?
          result = JSON.parse(response.body)
          deliveries_arr = result["deliveries"].as_a

          if deliveries_arr.empty?
            puts "No deliveries recorded."
          else
            printf "%-6s %-6s %-8s %-30s %s\n", "Seq", "HTTP", "Ms", "Error", "Time"
            printf "%-6s %-6s %-8s %-30s %s\n", "-" * 4, "-" * 4, "-" * 6, "-" * 28, "-" * 20
            deliveries_arr.each do |d|
              seq = d["store_seq"]
              status = d["status_code"].raw.nil? ? "-" : d["status_code"].to_s
              ms = d["response_ms"].raw.nil? ? "-" : d["response_ms"].to_s
              error = d["error"].raw.nil? ? "-" : truncate(d["error"].as_s, 28)
              time = d["attempted_at"].raw.nil? ? "-" : d["attempted_at"].as_s
              printf "%-6s %-6s %-8s %-30s %s\n", seq, status, ms, error, time
            end
          end
        else
          Output.error("Failed (#{response.status_code}): #{response.body}")
        end
      end

      # --- Helpers ---

      private def self.parse_store_name(name : String) : Tuple(String, String)
        parts = name.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end
        {parts[0], parts[1]}
      end

      private def self.auth_headers(config : Config, content_type : String? = nil) : HTTP::Headers
        headers = HTTP::Headers{"Authorization" => "Bearer #{config.token.not_nil!}"}
        headers["Content-Type"] = content_type if content_type
        headers
      end

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
