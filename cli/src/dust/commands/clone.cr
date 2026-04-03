require "json"
require "http/client"

module Dust
  module Commands
    module Clone
      def self.clone(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 2, "dust clone <source-store> <target-name>")

        source_store = args[0]
        target_name = args[1]

        parts = source_store.split("/")
        if parts.size != 2
          Output.error("Source store must be in org/store format")
        end

        base_url = derive_http_url(config.server_url)
        url = "#{base_url}/api/stores/#{parts[0]}/#{parts[1]}/clone"

        response = HTTP::Client.post(url,
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{config.token.not_nil!}",
            "Content-Type"  => "application/json",
          },
          body: {"name" => target_name}.to_json
        )

        if response.status_code == 201
          result = JSON.parse(response.body)
          Output.success("Cloned to #{result["store"]["full_name"]}")
        else
          Output.error("Clone failed (#{response.status_code}): #{response.body}")
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
