require "phoenix_client"
require "json"
require "uri"

module Dust
  # Wraps Phoenix::Socket to provide a synchronous, blocking API
  # for CLI commands. Handles reconnection, heartbeat, and channel
  # management via the phoenix_client shard.
  class Connection
    alias EventHandler = Proc(String, JSON::Any, Nil)

    @socket : Phoenix::Socket
    @channels : Hash(String, StoreChannel) = {} of String => StoreChannel
    @event_handler : EventHandler?
    @explicitly_closed : Bool = false

    def initialize(@config : Config)
      @socket = Phoenix::Socket.new(
        endpoint: build_endpoint,
        params: -> { build_params },
        heartbeat_interval: 30.seconds,
        timeout: 10.seconds,
      )
    end

    # Connect and block until the WebSocket handshake completes.
    def connect_sync(timeout : Time::Span = 5.seconds)
      ready = ::Channel(Nil).new(1)
      error = ::Channel(Exception).new(1)

      @socket.on_open { ready.send(nil) }
      @socket.on_error { |ex| error.send(ex) }
      @socket.connect

      select
      when ready.receive
        # connected
      when ex = error.receive
        raise "Connection failed: #{ex.message}"
      when timeout(timeout)
        raise "Connection timed out"
      end
    end

    # Join a store channel. Blocks until the server replies.
    def join(store : String, last_store_seq : Int64 = 0_i64) : StoreChannel
      topic = "store:#{store}"
      params = {"last_store_seq" => JSON::Any.new(last_store_seq)}

      phoenix_channel = @socket.channel(topic, params)
      store_channel = StoreChannel.new(phoenix_channel, topic)

      # Wire up broadcast events to the CLI's event handler
      phoenix_channel.on("event") do |payload|
        @event_handler.try(&.call(topic, payload))
      end

      # Join and block for reply
      result = ::Channel(JSON::Any).new(1)
      join_error = ::Channel(String).new(1)

      phoenix_channel.join
        .receive("ok") { |resp| result.send(resp) }
        .receive("error") { |resp| join_error.send(resp.to_json) }
        .receive("timeout") { |_| join_error.send("join timed out") }

      select
      when resp = result.receive
        store_channel.store_seq = resp["store_seq"].as_i64
      when err = join_error.receive
        raise "Join failed: #{err}"
      when timeout(10.seconds)
        raise "Join timed out"
      end

      @channels[topic] = store_channel
      store_channel
    end

    # Register a handler for server-pushed events (broadcasts).
    def on_event(&handler : EventHandler)
      @event_handler = handler
    end

    # Gracefully close the WebSocket connection.
    def close
      @explicitly_closed = true
      @socket.disconnect
    end

    # Returns true if the connection has not been explicitly closed.
    # Stays true during reconnection attempts (unlike socket.connected?).
    def running? : Bool
      !@explicitly_closed
    end

    private def build_endpoint : String
      base = URI.parse(@config.server_url)
      path = (base.path || "").rstrip('/')
      path += "/websocket" unless path.ends_with?("/websocket")
      scheme = base.scheme == "wss" ? "wss" : "ws"
      port = base.port
      port_str = port ? ":#{port}" : ""
      "#{scheme}://#{base.host}#{port_str}#{path}"
    end

    private def build_params : Hash(String, String)
      {
        "token"     => @config.token.not_nil!,
        "device_id" => @config.device_id,
        "capver"    => "1",
      }
    end
  end
end
