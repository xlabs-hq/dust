require "json"
require "http/client"

module Dust
  module Commands
    module Export
      def self.export(config : Config, args : Array(String))
        Output.require_auth!(config)

        format = "jsonl"
        store_name = ""
        remaining = [] of String

        i = 0
        while i < args.size
          if args[i] == "--format" && i + 1 < args.size
            format = args[i + 1]
            i += 2
          else
            remaining << args[i]
            i += 1
          end
        end

        if remaining.empty?
          Output.error("Usage: dust export <store> [--format jsonl|sqlite]")
        end
        store_name = remaining[0]

        parts = store_name.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end

        base_url = derive_http_url(config.server_url)
        url = "#{base_url}/api/stores/#{parts[0]}/#{parts[1]}/export?format=#{format}"

        response = HTTP::Client.get(url, headers: HTTP::Headers{
          "Authorization" => "Bearer #{config.token.not_nil!}",
        })

        if response.status.success?
          STDOUT.print response.body
        else
          Output.error("Export failed (#{response.status_code}): #{response.body}")
        end
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
