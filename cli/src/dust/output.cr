require "json"

module Dust
  module Output
    def self.json(data)
      puts data.to_pretty_json
    end

    def self.error(message : String)
      STDERR.puts "Error: #{message}"
      exit 1
    end

    def self.success(message : String)
      puts message
    end

    def self.require_auth!(config : Config)
      unless config.authenticated?
        error("Not authenticated. Run `dust login` first.")
      end
    end

    def self.require_args!(args : Array(String), min : Int32, usage : String)
      if args.size < min
        error("Usage: #{usage}")
      end
    end
  end
end
