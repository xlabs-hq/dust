require "json"
require "http/client"

module Dust
  module Commands
    module Import
      def self.import_data(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 1, "dust import <store> < file.jsonl")

        store_name = args[0]
        parts = store_name.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end

        body = STDIN.gets_to_end

        base_url = derive_http_url(config.server_url)
        url = "#{base_url}/api/stores/#{parts[0]}/#{parts[1]}/import"

        response = HTTP::Client.post(url,
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
            "Content-Type"  => "application/x-ndjson",
          },
          body: body
        )

        if response.status.success?
          result = JSON.parse(response.body)
          Output.success("Imported #{result["entries_imported"]} entries")
        else
          Output.error("Import failed (#{response.status_code}): #{response.body}")
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
