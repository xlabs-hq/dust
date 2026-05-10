require "spec"
require "../../src/dust/config"
require "../../src/dust/client/channel"
require "../../src/dust/client/connection"

describe Dust::Connection do
  describe "#build_endpoint" do
    it "appends /websocket to a ws:// path" do
      config = Dust::Config.new
      config.token = "test_token_abc"
      config.server_url = "ws://localhost:7755/ws/sync"

      conn = Dust::Connection.new(config)
      conn.build_endpoint.should eq "ws://localhost:7755/ws/sync/websocket"
    end

    it "preserves wss://" do
      config = Dust::Config.new
      config.token = "tok"
      config.server_url = "wss://dust.example.com/ws/sync"

      conn = Dust::Connection.new(config)
      conn.build_endpoint.should eq "wss://dust.example.com/ws/sync/websocket"
    end

    it "does not double-append /websocket" do
      config = Dust::Config.new
      config.token = "tok"
      config.server_url = "ws://localhost:7755/ws/sync/websocket"

      conn = Dust::Connection.new(config)
      conn.build_endpoint.should eq "ws://localhost:7755/ws/sync/websocket"
    end

    it "handles path with trailing slash" do
      config = Dust::Config.new
      config.token = "tok"
      config.server_url = "ws://localhost:7755/ws/sync/"

      conn = Dust::Connection.new(config)
      conn.build_endpoint.should eq "ws://localhost:7755/ws/sync/websocket"
    end
  end

  describe "#build_params" do
    it "includes token, device_id, and capver=2" do
      config = Dust::Config.new
      config.token = "test_token_abc"

      conn = Dust::Connection.new(config)
      params = conn.build_params

      params["token"].should eq "test_token_abc"
      params["device_id"].should eq config.device_id
      params["capver"].should eq "2"
    end

    it "includes device_id from config" do
      config = Dust::Config.new
      config.token = "tok"
      config.device_id = "dev_custom123"

      conn = Dust::Connection.new(config)
      conn.build_params["device_id"].should eq "dev_custom123"
    end
  end

end
