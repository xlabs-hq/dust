require "json"

module Dust
  # Represents a joined Phoenix Channel topic (e.g. "store:james/blog").
  # Holds join state and provides a push helper that delegates to Connection.
  #
  # Named StoreChannel to avoid collision with Crystal's stdlib Channel(T)
  # used for fiber communication.
  class StoreChannel
    getter topic : String
    getter join_ref : String
    property store_seq : Int64 = 0_i64

    def initialize(@connection : Connection, @topic : String, @join_ref : String)
    end

    # Push an event to the server and wait for the reply.
    def push(event : String, payload : Hash(String, JSON::Any)) : JSON::Any
      @connection.push(@topic, event, payload)
    end

    # Called by Connection when the join reply arrives.
    def handle_join_reply(reply : JSON::Any)
      status = reply["status"].as_s
      raise "Join failed: #{reply.to_json}" unless status == "ok"
      response = reply["response"]
      @store_seq = response["store_seq"].as_i64
    end
  end
end
