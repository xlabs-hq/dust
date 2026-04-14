defmodule DustProtocol do
  @moduledoc "Shared wire protocol types for Dust server and SDKs."

  # Capability version history
  # 1: Initial protocol — JSON wire format, all current op types
  # 2: Adds optional `if_match` (CAS) on `set` writes with leaf values; introduces `conflict` reply
  @current_capver 2
  @min_capver 1

  def current_capver, do: @current_capver
  def min_capver, do: @min_capver
end
