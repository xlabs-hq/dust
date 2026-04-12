require "json"
require "http/client"
require "uri"

module Dust
  module Commands
    module Init
      def self.init(config : Config, args : Array(String))
        Output.require_auth!(config)

        # Parse flags
        store_arg : String? = nil
        org_flag : String? = nil
        ttl_flag : Int64? = nil

        i = 0
        while i < args.size
          case args[i]
          when "--org"
            if i + 1 >= args.size
              Output.error("--org requires a value")
            end
            org_flag = args[i + 1]
            i += 2
          when "--ttl"
            if i + 1 >= args.size
              Output.error("--ttl requires a value")
            end
            ttl_flag = args[i + 1].to_i64
            i += 2
          when "--help", "-h"
            print_usage
            return
          else
            # Positional arg: org/store or just store
            if args[i].includes?("/")
              store_arg = args[i]
            elsif !args[i].starts_with?("-")
              store_arg = args[i]
            end
            i += 1
          end
        end

        # Detect project
        unless File.exists?("package.json")
          Output.error("No package.json found. Run `dust init` from a TypeScript/Node.js project directory.")
        end

        # Always fetch org slug from the API (determined by auth token)
        base_url = derive_http_url(config.server_url)
        org_slug = fetch_org_slug(config, base_url)

        # Warn if user-provided --org doesn't match the token's org
        if org_flag && org_flag != org_slug
          puts "Warning: --org #{org_flag} does not match your token's org (#{org_slug}). Using #{org_slug}."
        end

        # Derive store name
        store_name = if sa = store_arg
                       parts = sa.split("/")
                       if parts.size == 2
                         # org/store format — extract store name but use the token's org
                         if parts[0] != org_slug
                           puts "Warning: org '#{parts[0]}' does not match your token's org (#{org_slug}). Using #{org_slug}."
                         end
                         parts[1]
                       else
                         sa
                       end
                     else
                       detect_store_name
                     end

        full_name = "#{org_slug}/#{store_name}"

        puts ""
        puts "Detected TypeScript project: #{store_name}"
        puts ""

        # Check if already configured
        if env_has_key?("DUST_API_KEY")
          puts "Already configured — .env contains DUST_API_KEY"
          puts "Store: #{full_name}"
          return
        end

        # Create store (ignore error if already exists)
        create_body = {} of String => JSON::Any
        create_body["name"] = JSON::Any.new(store_name)
        create_body["ttl"] = JSON::Any.new(ttl_flag) if ttl_flag

        store_resp = HTTP::Client.post(
          "#{base_url}/api/stores",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
            "Content-Type"  => "application/json",
          },
          body: create_body.to_json
        )

        case store_resp.status_code
        when 201
          puts "Created store: #{full_name}"
        when 422
          puts "Store #{full_name} already exists — using it"
        when 402
          Output.error("Store limit reached. Upgrade your plan to create more stores.")
        else
          Output.error("Failed to create store (#{store_resp.status_code}): #{store_resp.body}")
        end

        # Create token for the new store
        token_body = {} of String => JSON::Any
        token_body["store_name"] = JSON::Any.new(store_name)
        token_body["name"] = JSON::Any.new("dust-init-#{store_name}")
        token_body["read"] = JSON::Any.new(true)
        token_body["write"] = JSON::Any.new(true)

        token_resp = HTTP::Client.post(
          "#{base_url}/api/tokens",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
            "Content-Type"  => "application/json",
          },
          body: token_body.to_json
        )

        unless token_resp.status_code == 201
          Output.error("Failed to create token (#{token_resp.status_code}): #{token_resp.body}")
        end

        token_result = JSON.parse(token_resp.body)
        raw_token = token_result["raw_token"].as_s

        # Derive the URL for the .env
        dust_url = config.server_url

        # Write .env
        write_env(dust_url, raw_token)

        masked = raw_token.size > 16 ? raw_token[0..15] + "..." : raw_token

        puts "Generated token: #{masked}"
        puts ""
        puts "Wrote .env:"
        puts "  DUST_URL=#{dust_url}"
        puts "  DUST_API_KEY=#{masked}"
        puts ""
        puts "Get started:"
        puts ""
        puts "  import { Dust } from '@dust-sync/sdk'"
        puts ""
        puts "  const dust = new Dust({"
        puts "    url: process.env.DUST_URL!,"
        puts "    token: process.env.DUST_API_KEY!,"
        puts "  })"
        puts ""
        puts "  await dust.put('#{full_name}', 'hello', 'world')"
        puts "  const value = await dust.get('#{full_name}', 'hello')"
        puts ""
      end

      private def self.fetch_org_slug(config : Config, base_url : String) : String
        resp = HTTP::Client.get(
          "#{base_url}/api/stores",
          headers: HTTP::Headers{"Authorization" => "Bearer #{config.token.not_nil!}"}
        )

        unless resp.status.success?
          Output.error("Failed to fetch org info. Check your auth token.")
        end

        result = JSON.parse(resp.body)

        # Prefer the top-level org field
        org = result["org"]?.try(&.as_s)
        return org if org

        # Fallback: extract from first store's full_name
        stores = result["stores"]?.try(&.as_a)
        if stores && !stores.empty?
          full = stores[0]["full_name"]?.try(&.as_s)
          if full
            parts = full.split("/")
            return parts[0] if parts.size == 2
          end
        end

        Output.error("Could not determine organization. Use --org flag.")
        raise "unreachable"
      end

      private def self.detect_store_name : String
        if File.exists?("package.json")
          pkg = JSON.parse(File.read("package.json"))
          name = pkg["name"]?.try(&.as_s)
          if name
            # Sanitize: strip @scope/ prefix, lowercase, replace non-alphanumeric with dashes
            clean = name.gsub(/@[^\/]+\//, "").downcase.gsub(/[^a-z0-9._-]/, "-").strip("-")
            return clean unless clean.empty?
          end
        end

        # Fallback to directory name
        Dir.current.split("/").last.downcase.gsub(/[^a-z0-9._-]/, "-")
      end

      private def self.env_has_key?(key : String) : Bool
        return false unless File.exists?(".env")
        File.read_lines(".env").any? { |line| line.starts_with?("#{key}=") }
      end

      private def self.write_env(url : String, token : String)
        lines = [] of String

        if File.exists?(".env")
          lines = File.read_lines(".env")
        end

        # Append only missing keys
        unless lines.any? { |l| l.starts_with?("DUST_URL=") }
          lines << "DUST_URL=#{url}"
        end

        unless lines.any? { |l| l.starts_with?("DUST_API_KEY=") }
          lines << "DUST_API_KEY=#{token}"
        end

        File.write(".env", lines.join("\n") + "\n")
      end

      private def self.derive_http_url(server_url : String) : String
        uri = URI.parse(server_url)
        scheme = (uri.scheme == "wss") ? "https" : "http"
        port_str = uri.port ? ":#{uri.port}" : ""
        "#{scheme}://#{uri.host}#{port_str}"
      end

      private def self.print_usage
        puts <<-USAGE
        Usage: dust init [options] [org/store]

        Zero-config project setup. Detects your TypeScript project,
        creates a store, generates a token, and writes .env.

        Options:
          --org <slug>    Organization slug (auto-detected if omitted)
          --ttl <seconds> Store TTL in seconds
          -h, --help      Show this help

        Examples:
          dust init                    Auto-detect everything
          dust init --org myorg        Explicit org, auto store name
          dust init myorg/mystore      Fully explicit
        USAGE
      end
    end
  end
end
