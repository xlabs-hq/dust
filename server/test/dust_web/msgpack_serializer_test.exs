defmodule DustWeb.MsgpackSerializerTest do
  use ExUnit.Case, async: true

  alias DustWeb.MsgpackSerializer
  alias Phoenix.Socket.{Broadcast, Message, Reply}

  describe "encode!/1 Message with map payload" do
    test "encodes as binary msgpack frame" do
      msg = %Message{
        join_ref: "1",
        ref: "2",
        topic: "store:abc",
        event: "op:put",
        payload: %{"key" => "greeting", "value" => "hello"}
      }

      assert {:socket_push, :binary, encoded} = MsgpackSerializer.encode!(msg)
      assert is_binary(encoded)

      # Decode the msgpack to verify contents
      assert ["1", "2", "store:abc", "op:put", %{"key" => "greeting", "value" => "hello"}] =
               Msgpax.unpack!(encoded)
    end

    test "roundtrips through encode then decode" do
      msg = %Message{
        join_ref: "1",
        ref: "2",
        topic: "store:abc",
        event: "op:put",
        payload: %{"key" => "greeting", "value" => "hello"}
      }

      {:socket_push, :binary, encoded} = MsgpackSerializer.encode!(msg)
      decoded = MsgpackSerializer.decode!(encoded, opcode: :binary)

      assert decoded.join_ref == "1"
      assert decoded.ref == "2"
      assert decoded.topic == "store:abc"
      assert decoded.event == "op:put"
      assert decoded.payload == %{"key" => "greeting", "value" => "hello"}
    end
  end

  describe "encode!/1 Reply with map payload" do
    test "encodes as binary msgpack frame with phx_reply event" do
      reply = %Reply{
        join_ref: "1",
        ref: "3",
        topic: "store:abc",
        status: :ok,
        payload: %{"data" => "value"}
      }

      assert {:socket_push, :binary, encoded} = MsgpackSerializer.encode!(reply)
      assert is_binary(encoded)

      assert [
               "1",
               "3",
               "store:abc",
               "phx_reply",
               %{"status" => "ok", "response" => %{"data" => "value"}}
             ] =
               Msgpax.unpack!(encoded)
    end
  end

  describe "fastlane!/1 Broadcast with map payload" do
    test "encodes as binary msgpack frame" do
      broadcast = %Broadcast{
        topic: "store:abc",
        event: "op:put",
        payload: %{"key" => "greeting", "value" => "hello"}
      }

      assert {:socket_push, :binary, encoded} = MsgpackSerializer.fastlane!(broadcast)
      assert is_binary(encoded)

      assert [nil, nil, "store:abc", "op:put", %{"key" => "greeting", "value" => "hello"}] =
               Msgpax.unpack!(encoded)
    end
  end

  describe "encode!/1 Message with binary payload" do
    test "uses compact header format" do
      binary_data = <<1, 2, 3, 4, 5>>

      msg = %Message{
        join_ref: "1",
        ref: "2",
        topic: "store:abc",
        event: "bin:upload",
        payload: {:binary, binary_data}
      }

      assert {:socket_push, :binary, encoded} = MsgpackSerializer.encode!(msg)

      # First byte should be @push (0) indicating header format
      assert <<0::size(8), _::binary>> = encoded

      # Roundtrip through decode should recover the binary payload
      decoded = MsgpackSerializer.decode!(encoded, opcode: :binary)
      assert decoded.join_ref == "1"
      assert decoded.ref == nil
      assert decoded.topic == "store:abc"
      assert decoded.event == "bin:upload"
      assert decoded.payload == {:binary, binary_data}
    end
  end

  describe "encode!/1 Reply with binary payload" do
    test "uses compact header format" do
      binary_data = <<10, 20, 30>>

      reply = %Reply{
        join_ref: "1",
        ref: "3",
        topic: "store:abc",
        status: :ok,
        payload: {:binary, binary_data}
      }

      assert {:socket_push, :binary, encoded} = MsgpackSerializer.encode!(reply)

      # First byte should be @reply (1) indicating header format
      assert <<1::size(8), _::binary>> = encoded
    end
  end

  describe "fastlane!/1 Broadcast with binary payload" do
    test "uses compact header format" do
      binary_data = <<99, 100>>

      broadcast = %Broadcast{
        topic: "store:abc",
        event: "bin:data",
        payload: {:binary, binary_data}
      }

      assert {:socket_push, :binary, encoded} = MsgpackSerializer.fastlane!(broadcast)

      # First byte should be @broadcast (2) indicating header format
      assert <<2::size(8), _::binary>> = encoded
    end
  end

  describe "decode!/2 msgpack binary frame" do
    test "decodes a msgpack-encoded binary frame" do
      raw =
        Msgpax.pack!(["j1", "r1", "store:xyz", "event:test", %{"foo" => "bar"}], iodata: false)

      decoded = MsgpackSerializer.decode!(raw, opcode: :binary)

      assert %Message{} = decoded
      assert decoded.join_ref == "j1"
      assert decoded.ref == "r1"
      assert decoded.topic == "store:xyz"
      assert decoded.event == "event:test"
      assert decoded.payload == %{"foo" => "bar"}
    end
  end

  describe "decode!/2 text frame (JSON fallback)" do
    test "decodes a JSON text frame" do
      raw = Jason.encode!(["j1", "r1", "store:xyz", "event:test", %{"foo" => "bar"}])

      decoded = MsgpackSerializer.decode!(raw, opcode: :text)

      assert %Message{} = decoded
      assert decoded.join_ref == "j1"
      assert decoded.ref == "r1"
      assert decoded.topic == "store:xyz"
      assert decoded.event == "event:test"
      assert decoded.payload == %{"foo" => "bar"}
    end
  end

  describe "output type" do
    test "map payload always produces :binary (not :text)" do
      msg = %Message{
        join_ref: "1",
        ref: "2",
        topic: "t",
        event: "e",
        payload: %{}
      }

      assert {:socket_push, :binary, _} = MsgpackSerializer.encode!(msg)

      reply = %Reply{
        join_ref: "1",
        ref: "2",
        topic: "t",
        status: :ok,
        payload: %{}
      }

      assert {:socket_push, :binary, _} = MsgpackSerializer.encode!(reply)

      broadcast = %Broadcast{topic: "t", event: "e", payload: %{}}
      assert {:socket_push, :binary, _} = MsgpackSerializer.fastlane!(broadcast)
    end
  end

  describe "error cases" do
    test "encode! raises for invalid Message payload" do
      msg = %Message{
        join_ref: "1",
        ref: "2",
        topic: "t",
        event: "e",
        payload: "not a map"
      }

      assert_raise ArgumentError, ~r/expected payload to be a map/, fn ->
        MsgpackSerializer.encode!(msg)
      end
    end

    test "fastlane! raises for invalid Broadcast payload" do
      broadcast = %Broadcast{topic: "t", event: "e", payload: "not a map"}

      assert_raise ArgumentError, ~r/expected broadcasted payload to be a map/, fn ->
        MsgpackSerializer.fastlane!(broadcast)
      end
    end
  end
end
