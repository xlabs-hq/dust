defmodule DustProtocolTest do
  use ExUnit.Case

  test "current_capver returns the protocol version" do
    assert DustProtocol.current_capver() == 3
  end

  test "min_capver returns the minimum supported version" do
    # Bumped to 3 with the segment-first paths break: pre-launch, no
    # back-compat for capver < 3 clients.
    assert DustProtocol.min_capver() == 3
  end
end
