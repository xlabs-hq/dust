defmodule DustProtocol.CodecTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Codec

  @hello %{type: "hello", capver: 1, device_id: "dev_1", token: "dust_tok_abc"}

  describe "msgpack" do
    test "round-trips a hello message" do
      {:ok, packed} = Codec.encode(:msgpack, @hello)
      assert is_binary(packed)
      {:ok, decoded} = Codec.decode(:msgpack, packed)
      assert decoded["type"] == "hello"
      assert decoded["capver"] == 1
    end
  end

  describe "json" do
    test "round-trips a hello message" do
      {:ok, encoded} = Codec.encode(:json, @hello)
      assert is_binary(encoded)
      {:ok, decoded} = Codec.decode(:json, encoded)
      assert decoded["type"] == "hello"
      assert decoded["capver"] == 1
    end
  end

  describe "event encoding" do
    test "encodes a canonical event" do
      event = %{
        type: "event",
        store: "james/blog",
        store_seq: 42,
        op: "set",
        path: "posts.hello",
        value: %{"title" => "Hello"},
        device_id: "dev_1",
        client_op_id: "op_1"
      }

      {:ok, packed} = Codec.encode(:msgpack, event)
      {:ok, decoded} = Codec.decode(:msgpack, packed)
      assert decoded["store_seq"] == 42
      assert decoded["op"] == "set"
    end
  end
end
