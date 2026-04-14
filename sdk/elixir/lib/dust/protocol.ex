defmodule Dust.Protocol do
  @moduledoc "Shared wire protocol types for Dust SDKs."

  @current_capver 2
  @min_capver 1

  def current_capver, do: @current_capver
  def min_capver, do: @min_capver
end
