require "json"

module Dust
  class Config
    CONFIG_DIR = Path.new(ENV.fetch("XDG_CONFIG_HOME", Path.home.join(".config").to_s)).join("dust").to_s
    DATA_DIR   = Path.new(ENV.fetch("XDG_DATA_HOME", Path.home.join(".local", "share").to_s)).join("dust").to_s

    CREDENTIALS_FILE = File.join(CONFIG_DIR, "credentials.json")
    CONFIG_FILE      = File.join(CONFIG_DIR, "config.json")

    property token : String?
    property device_id : String
    property server_url : String

    def initialize
      @token = ENV["DUST_API_KEY"]?
      @device_id = "dev_" + Random::Secure.hex(8)
      @server_url = "ws://localhost:7755/ws/sync"
      load_credentials
      load_config
    end

    def save_credentials(token : String)
      Dir.mkdir_p(CONFIG_DIR)
      File.write(CREDENTIALS_FILE, {
        token:      token,
        device_id:  @device_id,
        server_url: @server_url,
      }.to_json)
      @token = token
    end

    def authenticated? : Bool
      !@token.nil?
    end

    private def load_credentials
      return unless File.exists?(CREDENTIALS_FILE)
      data = JSON.parse(File.read(CREDENTIALS_FILE))
      @token ||= data["token"]?.try(&.as_s)
      @device_id = data["device_id"]?.try(&.as_s) || @device_id
      @server_url = data["server_url"]?.try(&.as_s) || @server_url
    end

    private def load_config
      return unless File.exists?(CONFIG_FILE)
      data = JSON.parse(File.read(CONFIG_FILE))
      @server_url = data["server_url"]?.try(&.as_s) || @server_url
    end
  end
end
