require "json"

module Dust
  # Wraps a Phoenix::Channel to provide a synchronous push API.
  # Named StoreChannel to avoid collision with Crystal's stdlib Channel(T).
  class StoreChannel
    getter topic : String
    property store_seq : Int64 = 0_i64

    def initialize(@channel : Phoenix::Channel, @topic : String)
    end

    # Push an event to the server and block for the reply.
    # Returns a JSON object with "status" and "response" keys,
    # matching the shape the CLI commands already expect.
    def push(event : String, payload : Hash(String, JSON::Any)) : JSON::Any
      result = ::Channel(JSON::Any).new(1)
      error = ::Channel(String).new(1)

      @channel.push(event, JSON.parse(payload.to_json))
        .receive("ok") { |resp| result.send(wrap_reply("ok", resp)) }
        .receive("error") { |resp| result.send(wrap_reply("error", resp)) }
        .receive("timeout") { |_| error.send("push timed out") }

      select
      when resp = result.receive
        resp
      when err = error.receive
        raise err
      when timeout(10.seconds)
        raise "Timeout waiting for reply"
      end
    end

    private def wrap_reply(status : String, response : JSON::Any) : JSON::Any
      JSON::Any.new({
        "status"   => JSON::Any.new(status),
        "response" => response,
      })
    end
  end
end
