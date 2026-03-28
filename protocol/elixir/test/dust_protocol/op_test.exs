defmodule DustProtocol.OpTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Op

  describe "valid_op?/1" do
    test "accepts core ops" do
      assert Op.valid_op?(:set)
      assert Op.valid_op?(:delete)
      assert Op.valid_op?(:merge)
    end

    test "rejects unknown ops" do
      refute Op.valid_op?(:unknown)
    end
  end

  describe "new/1" do
    test "builds a set op" do
      op = Op.new(op: :set, path: "posts.hello", value: %{"title" => "Hello"}, device_id: "dev_1", client_op_id: "op_1")
      assert op.op == :set
      assert op.path == "posts.hello"
      assert op.value == %{"title" => "Hello"}
      assert op.device_id == "dev_1"
      assert op.client_op_id == "op_1"
    end

    test "builds a delete op with nil value" do
      op = Op.new(op: :delete, path: "posts.old", device_id: "dev_1", client_op_id: "op_2")
      assert op.op == :delete
      assert op.value == nil
    end
  end
end
