require "http/web_socket"
require "json"
require "uri"

module Dust
  # Phoenix Channel v2 JSON protocol client over WebSocket.
  #
  # Wire format: each message is a JSON array:
  #   [join_ref, ref, topic, event, payload]
  #
  # The connection authenticates via query params (token, device_id, capver, vsn)
  # and speaks the V2 JSON serializer format expected by Phoenix.Socket.V2.JSONSerializer.
  class Connection
    alias ReplyChannel = ::Channel(JSON::Any)
    alias EventHandler = Proc(String, JSON::Any, Nil)

    @ws : HTTP::WebSocket?
    @ref_counter : Int32 = 0
    @channels : Hash(String, StoreChannel) = {} of String => StoreChannel
    @replies : Hash(String, ReplyChannel) = {} of String => ReplyChannel
    @running : Bool = false
    @event_handler : EventHandler?

    def initialize(@config : Config)
    end

    # Connect the WebSocket (non-blocking). Spawns heartbeat and listener fibers.
    def connect
      uri = build_uri
      @ws = HTTP::WebSocket.new(uri)
      @running = true
      spawn { run_heartbeat }
      spawn { listen }
    end

    # Connect and block briefly to let the WebSocket handshake complete.
    # Useful for CLI commands that need immediate interaction.
    def connect_sync
      connect
      sleep 0.1.seconds
    end

    # Join a store channel. Sends phx_join and waits for the reply.
    # Returns a StoreChannel with store_seq populated from the server response.
    def join(store : String, last_store_seq : Int64 = 0_i64) : StoreChannel
      ref = next_ref
      join_ref = ref
      topic = "store:#{store}"

      channel = StoreChannel.new(self, topic, join_ref)
      @channels[topic] = channel

      send_message(join_ref, ref, topic, "phx_join", {"last_store_seq" => last_store_seq})

      reply = wait_for_reply(ref)
      channel.handle_join_reply(reply)
      channel
    end

    # Push an event on an already-joined topic. Waits for the server reply.
    def push(topic : String, event : String, payload : Hash(String, JSON::Any)) : JSON::Any
      ref = next_ref
      join_ref = @channels[topic]?.try(&.join_ref)
      send_message(join_ref, ref, topic, event, payload)
      wait_for_reply(ref)
    end

    # Register a handler for server-pushed events (broadcasts).
    # The handler receives (topic, payload).
    def on_event(&handler : EventHandler)
      @event_handler = handler
    end

    # Gracefully close the WebSocket connection.
    def close
      @running = false
      @ws.try(&.close)
    end

    # Returns true if the connection is currently active.
    def running? : Bool
      @running
    end

    # Build a raw Phoenix v2 JSON message and send it over the WebSocket.
    # Public so StoreChannel can also call it if needed.
    def send_message(join_ref : String?, ref : String, topic : String, event : String, payload)
      msg = JSON.build do |json|
        json.array do
          if join_ref
            json.string join_ref
          else
            json.null
          end
          json.string ref
          json.string topic
          json.string event
          json.raw payload.to_json
        end
      end
      @ws.not_nil!.send(msg)
    end

    # Build the WebSocket URI with auth query params.
    # Appends /websocket to the configured path (Phoenix longpoll/ws transport suffix).
    def build_uri : URI
      base = URI.parse(@config.server_url)
      path = base.path || ""
      path = path.rstrip('/')
      path += "/websocket" unless path.ends_with?("/websocket")

      params = URI::Params.build do |p|
        p.add "token", @config.token.not_nil!
        p.add "device_id", @config.device_id
        p.add "capver", "1"
        p.add "vsn", "2.0.0"
      end

      URI.new(
        scheme: base.scheme == "wss" ? "wss" : "ws",
        host: base.host.not_nil!,
        port: base.port,
        path: path,
        query: params
      )
    end

    private def listen
      @ws.not_nil!.on_message do |message|
        handle_message(message)
      end
      @ws.not_nil!.run
    rescue ex
      @running = false
    end

    private def handle_message(raw : String)
      msg = JSON.parse(raw).as_a
      _join_ref = msg[0].as_s?
      ref = msg[1].as_s?
      topic = msg[2].as_s
      event = msg[3].as_s
      payload = msg[4]

      case event
      when "phx_reply"
        if ref && (reply_ch = @replies.delete(ref))
          reply_ch.send(payload)
        end
      when "event"
        @event_handler.try(&.call(topic, payload))
      when "phx_error"
        STDERR.puts "Channel error on #{topic}: #{payload}"
      when "phx_close"
        @channels.delete(topic)
      end
    end

    private def wait_for_reply(ref : String, timeout : Time::Span = 10.seconds) : JSON::Any
      ch = ReplyChannel.new(1)
      @replies[ref] = ch

      select
      when reply = ch.receive
        reply
      when timeout(timeout)
        @replies.delete(ref)
        raise "Timeout waiting for reply to ref #{ref}"
      end
    end

    private def run_heartbeat
      while @running
        sleep 30.seconds
        begin
          send_message(nil, next_ref, "phoenix", "heartbeat", {} of String => String)
        rescue
          break
        end
      end
    end

    private def next_ref : String
      @ref_counter += 1
      @ref_counter.to_s
    end
  end
end
