require "spec"
require "../../src/dust/config"
require "../../src/dust/client/channel"
require "../../src/dust/client/connection"

describe Dust::Connection do
  describe "#build_uri" do
    it "builds correct WebSocket URI with auth params" do
      config = Dust::Config.new
      config.token = "test_token_abc"
      config.server_url = "ws://localhost:7755/ws/sync"

      conn = Dust::Connection.new(config)
      uri = conn.build_uri

      uri.scheme.should eq "ws"
      uri.host.should eq "localhost"
      uri.port.should eq 7755
      uri.path.should eq "/ws/sync/websocket"

      params = URI::Params.parse(uri.query.not_nil!)
      params["token"].should eq "test_token_abc"
      params["device_id"].should eq config.device_id
      params["capver"].should eq "1"
      params["vsn"].should eq "2.0.0"
    end

    it "handles wss scheme" do
      config = Dust::Config.new
      config.token = "tok"
      config.server_url = "wss://dust.example.com/ws/sync"

      conn = Dust::Connection.new(config)
      uri = conn.build_uri

      uri.scheme.should eq "wss"
      uri.host.should eq "dust.example.com"
      uri.path.should eq "/ws/sync/websocket"
    end

    it "does not double-append /websocket" do
      config = Dust::Config.new
      config.token = "tok"
      config.server_url = "ws://localhost:7755/ws/sync/websocket"

      conn = Dust::Connection.new(config)
      uri = conn.build_uri

      uri.path.should eq "/ws/sync/websocket"
    end

    it "handles path with trailing slash" do
      config = Dust::Config.new
      config.token = "tok"
      config.server_url = "ws://localhost:7755/ws/sync/"

      conn = Dust::Connection.new(config)
      uri = conn.build_uri

      uri.path.should eq "/ws/sync/websocket"
    end

    it "includes device_id from config" do
      config = Dust::Config.new
      config.token = "tok"
      config.device_id = "dev_custom123"

      conn = Dust::Connection.new(config)
      uri = conn.build_uri

      params = URI::Params.parse(uri.query.not_nil!)
      params["device_id"].should eq "dev_custom123"
    end
  end

  describe "StoreChannel" do
    it "handles successful join reply" do
      config = Dust::Config.new
      config.token = "tok"
      conn = Dust::Connection.new(config)

      channel = Dust::StoreChannel.new(conn, "store:james/blog", "1")
      channel.store_seq.should eq 0_i64

      reply = JSON.parse(%({"status": "ok", "response": {"store_seq": 42}}))
      channel.handle_join_reply(reply)

      channel.store_seq.should eq 42_i64
      channel.topic.should eq "store:james/blog"
      channel.join_ref.should eq "1"
    end

    it "raises on failed join reply" do
      config = Dust::Config.new
      config.token = "tok"
      conn = Dust::Connection.new(config)

      channel = Dust::StoreChannel.new(conn, "store:james/blog", "1")
      reply = JSON.parse(%({"status": "error", "response": {"reason": "unauthorized"}}))

      expect_raises(Exception, /Join failed/) do
        channel.handle_join_reply(reply)
      end
    end
  end
end
