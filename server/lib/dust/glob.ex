defmodule Dust.Glob do
  @moduledoc """
  Glob matching for Dust paths.

  Patterns use `.` as the segment separator, `*` to match a single segment,
  and `**` to match any remaining segments (only supported at the tail of a
  pattern).
  """

  @doc "Returns `true` if `path` matches `pattern`."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(_path, "**"), do: true

  def match?(path, pattern) do
    do_match(String.split(path, "."), String.split(pattern, "."))
  end

  defp do_match([], []), do: true
  defp do_match(_rest, ["**"]), do: true
  defp do_match([], _), do: false
  defp do_match(_path, []), do: false

  defp do_match([_p | path_rest], ["*" | pattern_rest]) do
    do_match(path_rest, pattern_rest)
  end

  defp do_match([seg | path_rest], [seg | pattern_rest]) do
    do_match(path_rest, pattern_rest)
  end

  defp do_match(_, _), do: false
end
