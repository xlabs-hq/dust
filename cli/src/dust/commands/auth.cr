module Dust
  module Commands
    module Auth
      def self.login(config : Config, args : Array(String))
        STDOUT.print "Paste your Dust API token: "
        STDOUT.flush
        token = STDIN.gets
        if token.nil? || token.strip.empty?
          Output.error("No token provided.")
        end

        token = token.not_nil!.strip
        config.save_credentials(token)
        Output.success("Credentials saved. Device ID: #{config.device_id}")
      end

      def self.logout(config : Config, args : Array(String))
        path = Config::CREDENTIALS_FILE
        if File.exists?(path)
          File.delete(path)
          Output.success("Credentials removed.")
        else
          Output.success("No credentials to remove.")
        end
      end
    end
  end
end
