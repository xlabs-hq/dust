defmodule DustProtocolTest do
  use ExUnit.Case

  test "current_capver returns the protocol version" do
    assert DustProtocol.current_capver() == 2
  end

  test "min_capver returns the minimum supported version" do
    assert DustProtocol.min_capver() == 1
  end
end
