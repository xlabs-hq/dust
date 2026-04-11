defmodule Dust.Protocol.Glob do
  @doc "Compile a glob pattern string into a structured form for repeated matching."
  def compile(pattern) when is_binary(pattern) do
    {:compiled, String.split(pattern, ".")}
  end

  @doc "Test whether a glob pattern matches a path (list of segments)."
  def match?(pattern, path) when is_binary(pattern) and is_list(path) do
    do_match(String.split(pattern, "."), path)
  end

  def match?({:compiled, pattern_segments}, path) when is_list(path) do
    do_match(pattern_segments, path)
  end

  defp do_match([], []), do: true
  defp do_match([], _), do: false
  defp do_match(_, []), do: false

  defp do_match(["**"], [_ | _]), do: true

  defp do_match(["**" | rest], [_ | path_rest]) do
    # ** matches one or more: try matching rest of pattern against remaining path,
    # or consume another segment with **
    do_match(rest, path_rest) or do_match(["**" | rest], path_rest)
  end

  defp do_match(["*" | pattern_rest], [_ | path_rest]) do
    do_match(pattern_rest, path_rest)
  end

  defp do_match([segment | pattern_rest], [segment | path_rest]) do
    do_match(pattern_rest, path_rest)
  end

  defp do_match(_, _), do: false
end
