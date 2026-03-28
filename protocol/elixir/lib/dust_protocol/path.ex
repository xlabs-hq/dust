defmodule DustProtocol.Path do
  @doc "Parse a dotted path string into a list of segments."
  def parse(""), do: {:error, :empty_path}

  def parse(path) when is_binary(path) do
    segments = String.split(path, ".")

    if Enum.any?(segments, &(&1 == "")) do
      {:error, :empty_segment}
    else
      {:ok, segments}
    end
  end

  @doc "Join path segments into a dotted string."
  def to_string(segments) when is_list(segments) do
    Enum.join(segments, ".")
  end

  @doc "True if `a` is a strict ancestor of `b`."
  def ancestor?(a, b) when is_list(a) and is_list(b) do
    length(a) < length(b) and List.starts_with?(b, a)
  end

  @doc "True if paths are the same or one is an ancestor of the other."
  def related?(a, b) when is_list(a) and is_list(b) do
    a == b or ancestor?(a, b) or ancestor?(b, a)
  end
end
