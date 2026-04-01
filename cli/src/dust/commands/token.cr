module Dust
  module Commands
    module Token
      # dust token <subcommand>
      #
      # Token management requires REST API endpoints that are not yet available.
      # Direct users to the web dashboard for now.
      def self.token(config : Config, args : Array(String))
        subcommand = args.empty? ? nil : args[0]

        case subcommand
        when "create", "list", "revoke"
          puts "The `dust token #{subcommand}` command requires the web dashboard or REST API."
          puts ""
          puts "Manage your tokens at:"
          puts "  #{derive_http_url(config.server_url)}/dashboard/tokens"
          puts ""
          puts "This command will be fully implemented when REST API endpoints"
          puts "are added to the server."
        when "--help", "-h", nil
          puts "Usage: dust token <subcommand>"
          puts ""
          puts "Subcommands:"
          puts "  create    Create a new store token"
          puts "  list      List existing tokens"
          puts "  revoke    Revoke a token"
          puts ""
          puts "Note: Token management currently requires the web dashboard."
          puts "These commands will be implemented when REST API endpoints are added."
        else
          Output.error("Unknown token subcommand: #{subcommand}. Use: create, list, revoke")
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
