require "json"
require "base64"
require "http/client"

module Dust
  module Commands
    module Files
      # dust put-file <store> <path> <file>
      def self.put_file(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 3, "dust put-file <store> <path> <file>")

        store, path, file_path = args[0], args[1], args[2]

        unless File.exists?(file_path)
          Output.error("File not found: #{file_path}")
        end

        content = File.read(file_path)
        encoded = Base64.strict_encode(content)
        filename = File.basename(file_path)
        content_type = guess_content_type(file_path)

        conn = Connection.new(config)
        begin
          conn.connect_sync
          channel = conn.join(store)

          payload = {
            "path"         => JSON::Any.new(path),
            "content"      => JSON::Any.new(encoded),
            "filename"     => JSON::Any.new(filename),
            "content_type" => JSON::Any.new(content_type),
            "client_op_id" => JSON::Any.new(Random::Secure.hex(8)),
          } of String => JSON::Any

          result = channel.push("put_file", payload)

          status = result["status"].as_s
          unless status == "ok"
            reason = result["response"]?.try(&.["reason"]?.try(&.as_s)) || "unknown error"
            Output.error("Upload failed: #{reason}")
          end

          hash = result["response"]["hash"].as_s
          seq = result["response"]["store_seq"]
          Output.success("OK hash=#{hash} store_seq=#{seq}")
        ensure
          conn.close
        end
      end

      # dust fetch-file <store> <path> <dest>
      def self.fetch_file(config : Config, args : Array(String))
        Output.require_auth!(config)
        Output.require_args!(args, 3, "dust fetch-file <store> <path> <dest>")

        store_name, path, dest = args[0], args[1], args[2]

        # Step 1: Join channel and read the file reference from the store
        conn = Connection.new(config)
        cache = Cache.new
        last_seq = cache.last_seq(store_name)

        conn.on_event do |topic, payload|
          handle_event(cache, store_name, payload)
        end

        hash : String? = nil
        begin
          conn.connect_sync
          channel = conn.join(store_name, last_seq)

          # Wait for catch-up events to drain into cache
          sleep 0.2.seconds

          value = cache.read(store_name, path)
          if value.nil?
            Output.error("Path '#{path}' not found in store '#{store_name}'.")
          end

          # The value should be a file reference with a "hash" key
          hash = value.not_nil!["hash"]?.try(&.as_s)
          unless hash
            Output.error("Path '#{path}' does not contain a file reference (no hash field).")
          end
        ensure
          conn.close
          cache.close
        end

        # Step 2: HTTP GET to download the file
        http_base = derive_http_url(config.server_url)
        url = "#{http_base}/api/files/#{hash}"

        response = HTTP::Client.get(url, headers: HTTP::Headers{
          "Authorization" => "Bearer #{config.token.not_nil!}",
        })

        unless response.status.success?
          Output.error("Failed to download file: HTTP #{response.status_code} #{response.body}")
        end

        File.write(dest, response.body)
        Output.success("OK saved to #{dest} (#{response.body.bytesize} bytes)")
      end

      # --- Helpers ---

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
          cache.write(store_name, path, value, "map", seq)
        end
      end

      # Convert a WebSocket URL like ws://host:port/ws/sync to http://host:port
      private def self.derive_http_url(server_url : String) : String
        uri = URI.parse(server_url)
        scheme = (uri.scheme == "wss") ? "https" : "http"
        port_str = uri.port ? ":#{uri.port}" : ""
        "#{scheme}://#{uri.host}#{port_str}"
      end

      private def self.guess_content_type(file_path : String) : String
        ext = File.extname(file_path).lstrip('.')
        case ext
        when "json"             then "application/json"
        when "txt", "text"      then "text/plain"
        when "html", "htm"      then "text/html"
        when "css"              then "text/css"
        when "js"               then "application/javascript"
        when "png"              then "image/png"
        when "jpg", "jpeg"      then "image/jpeg"
        when "gif"              then "image/gif"
        when "svg"              then "image/svg+xml"
        when "pdf"              then "application/pdf"
        when "zip"              then "application/zip"
        when "csv"              then "text/csv"
        when "xml"              then "application/xml"
        when "mp3"              then "audio/mpeg"
        when "mp4"              then "video/mp4"
        when "webp"             then "image/webp"
        else                         "application/octet-stream"
        end
      end
    end
  end
end
