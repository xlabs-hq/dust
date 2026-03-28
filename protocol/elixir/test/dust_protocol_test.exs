defmodule DustProtocolTest do
  use ExUnit.Case

  test "capver returns the protocol version" do
    assert DustProtocol.capver() == 1
  end
end
