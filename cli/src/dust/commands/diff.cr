require "json"
require "http/client"

module Dust
  module Commands
    module Diff
      def self.diff(config : Config, args : Array(String))
        Output.require_auth!(config)

        if args.empty?
          Output.error("Usage: dust diff <store> --from-seq N [--to-seq M] [--json]")
        end

        store_name = args[0]
        from_seq = 0
        to_seq : String? = nil
        json_output = false

        i = 1
        while i < args.size
          case args[i]
          when "--from-seq"
            from_seq = args[i + 1].to_i
            i += 2
          when "--to-seq"
            to_seq = args[i + 1]
            i += 2
          when "--json"
            json_output = true
            i += 1
          else
            i += 1
          end
        end

        parts = store_name.split("/")
        if parts.size != 2
          Output.error("Store must be in org/store format")
        end

        base_url = derive_http_url(config.server_url)
        url = "#{base_url}/api/stores/#{parts[0]}/#{parts[1]}/diff?from_seq=#{from_seq}"
        url += "&to_seq=#{to_seq}" if to_seq

        response = HTTP::Client.get(url, headers: HTTP::Headers{
          "Authorization" => "Bearer #{config.token.not_nil!}",
        })

        if response.status.success?
          result = JSON.parse(response.body)
          if json_output
            puts result.to_pretty_json
          else
            render_colorized(result)
          end
        elsif response.status_code == 409
          result = JSON.parse(response.body)
          Output.error("Data compacted. Earliest available: seq #{result["earliest_available"]}")
        else
          Output.error("Diff failed (#{response.status_code}): #{response.body}")
        end
      end

      private def self.render_colorized(result : JSON::Any)
        from = result["from_seq"]
        to = result["to_seq"]
        changes = result["changes"].as_a

        puts "Diff: seq #{from} -> #{to} (#{changes.size} change#{changes.size == 1 ? "" : "s"})\n"

        changes.each do |change|
          path = change["path"].as_s
          before = change["before"]
          after_val = change["after"]

          if before.raw.nil?
            puts "\e[32m+ #{path} = #{format_value(after_val)}\e[0m"
          elsif after_val.raw.nil?
            puts "\e[31m- #{path} = #{format_value(before)}\e[0m"
          else
            puts "\e[33m~ #{path}\e[0m"
            puts "\e[31m  - #{format_value(before)}\e[0m"
            puts "\e[32m  + #{format_value(after_val)}\e[0m"
          end
        end

        puts "No changes." if changes.empty?
      end

      private def self.format_value(val : JSON::Any) : String
        case val.raw
        when String then val.as_s.inspect
        else             val.to_json
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
