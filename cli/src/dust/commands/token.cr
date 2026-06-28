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
          puts "  create <org/store|org/*> <name> [options]"
          puts "                                   Create a new token"
          puts "  list                             List existing tokens"
          puts "  revoke <id>                      Revoke a token"
          puts ""
          puts "Create options:"
          puts "  --read-only      Create a read-only token (default: read+write)"
          puts "  --all-stores     Grant access to all stores in the account"
          puts "  --scope SCOPE    Add a canonical scope (repeatable)"
        else
          Output.error("Unknown token subcommand: #{subcommand}. Use: create, list, revoke")
        end
      end

      # dust token create <org/store|org/*> <name> [--read-only] [--all-stores] [--scope SCOPE]
      def self.create(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust token create <org/store|org/*> <name> [--read-only] [--all-stores] [--scope SCOPE]")

        store_ref = args[0]
        name = args[1]
        read_only = false
        all_stores = false
        scopes = [] of String

        i = 2
        while i < args.size
          case args[i]
          when "--read-only"
            read_only = true
          when "--all-stores"
            all_stores = true
          when "--scope"
            i += 1
            Output.error("missing value for --scope") if i >= args.size
            scopes << args[i]
          else
            Output.error("Unknown token create option: #{args[i]}")
          end

          i += 1
        end

        parts = store_ref.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end

        store_name = parts[1]
        all_stores = true if store_name == "*"

        base_url = derive_http_url(config.server_url)
        body = {
          "name"              => JSON::Any.new(name),
          "store_access_mode" => JSON::Any.new(all_stores ? "all" : "selected"),
        } of String => JSON::Any

        if scopes.empty?
          body["read"] = JSON::Any.new(true)
          body["write"] = JSON::Any.new(!read_only)
        else
          body["scopes"] = JSON::Any.new(scopes.map { |scope| JSON::Any.new(scope) })
        end

        unless all_stores
          body["store_name"] = JSON::Any.new(store_name)
          body["store_names"] = JSON::Any.new([JSON::Any.new(store_name)])
        end

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
          puts "  Access:      #{access_string(result)}"
          puts "  Permissions: #{result["permissions"]}"
          puts "  Scopes:      #{scopes_string(result["scopes"]?)}"
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

        printf "%-38s %-16s %-18s %-6s %-28s %-20s\n", "ID", "Name", "Access", "Perms", "Scopes", "Last Used"
        printf "%-38s %-16s %-18s %-6s %-28s %-20s\n", "-" * 36, "-" * 14, "-" * 16, "-" * 5, "-" * 26, "-" * 18

        tokens.each do |token|
          id = token["id"].as_s[0..35]
          name = truncate(token["name"].as_s, 14)
          access = truncate(access_string(token), 16)
          perms = permission_string(token["permissions"])
          scopes = truncate(scopes_string(token["scopes"]?), 26)
          last_used = token["last_used_at"].raw.nil? ? "never" : token["last_used_at"].as_s
          printf "%-38s %-16s %-18s %-6s %-28s %-20s\n", id, name, access, perms, scopes, last_used
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

      private def self.access_string(token : JSON::Any) : String
        mode = token["store_access_mode"]?.try(&.as_s?) || "selected"
        return "all stores" if mode == "all"

        names = [] of String

        if stores = token["stores"]?
          stores.as_a.each do |store|
            if name = store["name"]?.try(&.as_s?)
              names << name
            end
          end
        end

        if names.empty?
          if store_name = token["store_name"]?.try(&.as_s?)
            names << store_name
          end
        end

        names.empty? ? "selected stores" : names.join(",")
      end

      private def self.scopes_string(scopes : JSON::Any?) : String
        return "-" unless scopes

        values = scopes.as_a.map(&.as_s)
        values.empty? ? "-" : values.join(",")
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
