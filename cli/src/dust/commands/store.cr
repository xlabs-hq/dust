module Dust
  module Commands
    module Store
      def self.create(config : Config, args : Array(String))
        Output.success("Store creation is not yet available from the CLI.")
        Output.success("Use the web dashboard to create stores.")
      end

      def self.list(config : Config, args : Array(String))
        Output.success("Store listing is not yet available from the CLI.")
        Output.success("Use the web dashboard to view your stores.")
      end

      def self.status(config : Config, args : Array(String))
        puts "Server:    #{config.server_url}"
        puts "Device ID: #{config.device_id}"

        if config.authenticated?
          token = config.token.not_nil!
          # Show only prefix of token for security
          visible = token.size > 12 ? token[0..11] + "..." : token
          puts "Auth:      #{visible}"
        else
          puts "Auth:      not authenticated"
        end
      end
    end
  end
end
