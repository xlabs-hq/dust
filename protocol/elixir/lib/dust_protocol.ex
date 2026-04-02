defmodule DustProtocol do
  @moduledoc "Shared wire protocol types for Dust server and SDKs."

  # Capability version history
  # 1: Initial protocol — JSON wire format, all current op types
  @current_capver 1
  @min_capver 1

  def current_capver, do: @current_capver
  def min_capver, do: @min_capver
end
