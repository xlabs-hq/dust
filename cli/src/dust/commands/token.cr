require "json"
require "http/client"

module Dust
  module Commands
    module Token
      def self.token(config : Config, args : Array(String))
        subcommand = args.empty? ? nil : args[0]
        rest = args.size > 1 ? args[1..] : [] of String

        case subcommand
        when "create" then create(config, rest)
        when "list"   then list(config, rest)
        when "revoke" then revoke(config, rest)
        when "--help", "-h", nil
          puts "Usage: dust token <subcommand>"
          puts ""
          puts "Subcommands:"
          puts "  create <store> <name> [options]  Create a new store token"
          puts "  list                             List existing tokens"
          puts "  revoke <id>                      Revoke a token"
          puts ""
          puts "Create options:"
          puts "  --read-only    Create a read-only token (default: read+write)"
        else
          Output.error("Unknown token subcommand: #{subcommand}. Use: create, list, revoke")
        end
      end

      # dust token create <org/store> <name> [--read-only]
      def self.create(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust token create <org/store> <name> [--read-only]")

        store_name = args[0]
        name = args[1]
        read_only = args.includes?("--read-only")

        parts = store_name.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end

        base_url = derive_http_url(config.server_url)
        body = {
          "store_name" => JSON::Any.new(parts[1]),
          "name"       => JSON::Any.new(name),
          "read"       => JSON::Any.new(true),
          "write"      => JSON::Any.new(!read_only),
        } of String => JSON::Any

        response = HTTP::Client.post(
          "#{base_url}/api/tokens",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
            "Content-Type"  => "application/json",
          },
          body: body.to_json
        )

        if response.status_code == 201
          result = JSON.parse(response.body)
          puts ""
          puts "Token created."
          puts ""
          puts "  Name:        #{result["name"]}"
          puts "  Store:       #{result["store_name"]}"
          puts "  Permissions: #{result["permissions"]}"
          puts "  Token:       #{result["raw_token"]}"
          puts ""
          puts "Save this token now -- it will not be shown again."
          puts ""
        else
          Output.error("Create failed (#{response.status_code}): #{response.body}")
        end
      end

      # dust token list
      def self.list(config : Config, args : Array(String))
        Output.require_auth!(config)

        json_output = args.includes?("--json")

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.get(
          "#{base_url}/api/tokens",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
          }
        )

        unless response.status.success?
          Output.error("Failed to list tokens (#{response.status_code}): #{response.body}")
        end

        result = JSON.parse(response.body)
        tokens = result["tokens"].as_a

        if json_output
          puts result.to_pretty_json
          return
        end

        if tokens.empty?
          puts "No tokens. Create one with: dust token create <org/store> <name>"
          return
        end

        printf "%-38s %-16s %-12s %-6s %-20s\n", "ID", "Name", "Store", "Perms", "Last Used"
        printf "%-38s %-16s %-12s %-6s %-20s\n", "-" * 36, "-" * 14, "-" * 10, "-" * 5, "-" * 18

        tokens.each do |token|
          id = token["id"].as_s[0..35]
          name = truncate(token["name"].as_s, 14)
          store = truncate(token["store_name"].as_s, 10)
          perms = permission_string(token["permissions"])
          last_used = token["last_used_at"].raw.nil? ? "never" : token["last_used_at"].as_s
          printf "%-38s %-16s %-12s %-6s %-20s\n", id, name, store, perms, last_used
        end
      end

      # dust token revoke <id>
      def self.revoke(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 1, "dust token revoke <id>")

        token_id = args[0]

        base_url = derive_http_url(config.server_url)
        response = HTTP::Client.delete(
          "#{base_url}/api/tokens/#{token_id}",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
          }
        )

        if response.status.success?
          Output.success("Token revoked.")
        else
          Output.error("Revoke failed (#{response.status_code}): #{response.body}")
        end
      end

      # --- Helpers ---

      private def self.permission_string(perms : JSON::Any) : String
        r = perms["read"].as_bool ? "r" : "-"
        w = perms["write"].as_bool ? "w" : "-"
        "#{r}#{w}"
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
