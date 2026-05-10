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
          imported = result["imported"]?.try(&.as_i) || 0
          skipped = result["skipped"]?.try(&.as_i) || 0
          unparseable = result["unparseable"]?.try(&.as_i) || 0
          failed = result["failed"]?.try(&.as_a) || [] of JSON::Any
          ok = result["ok"]?.try(&.as_bool?) || false

          if ok
            Output.success("Imported #{imported} entries (#{skipped} skipped)")
          else
            STDERR.puts "Imported #{imported} of #{imported + unparseable + failed.size} entries"
            STDERR.puts "  skipped:     #{skipped}"
            STDERR.puts "  unparseable: #{unparseable}"
            STDERR.puts "  failed:      #{failed.size}"

            failed.first(20).each do |f|
              line = f["line"]?.try(&.as_i) || "?"
              path = f["path"]?.try(&.as_s?) || "(unknown)"
              reason = f["reason"]?.try(&.as_s?) || "unknown"
              STDERR.puts "    line #{line}: #{path} — #{reason}"
            end

            STDERR.puts "    … and #{failed.size - 20} more" if failed.size > 20
            exit 1
          end
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
