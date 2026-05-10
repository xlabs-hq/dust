defmodule Dust.Protocol.Path do
  @moduledoc """
  Path utilities. Dust paths are dot-separated hierarchies, e.g.
  `"projects.alpha.title"`. Forward slashes are accepted as aliases
  for dots — so `Dust.put(store, "projects/alpha/title", val)` is
  equivalent to `Dust.put(store, "projects.alpha.title", val)`.

  Path segments cannot be empty. There is no escape for a literal
  `.` in a key — keys with dots in their names are not supported.
  """

  @doc """
  Normalize a dotted-or-slashed path into the canonical dotted form.

  Accepts either separator or a mix. Validates that no segment is
  empty.
  """
  @spec normalize(binary()) :: {:ok, binary()} | {:error, atom()}
  def normalize(""), do: {:error, :empty_path}

  def normalize(path) when is_binary(path) do
    canonical = String.replace(path, "/", ".")

    case parse(canonical) do
      {:ok, _} -> {:ok, canonical}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Normalize a glob pattern. Slashes become dots; `*` and `**` are
  valid segments.
  """
  @spec normalize_pattern(binary()) :: {:ok, binary()} | {:error, atom()}
  def normalize_pattern(""), do: {:error, :empty_path}

  def normalize_pattern(pattern) when is_binary(pattern) do
    canonical = String.replace(pattern, "/", ".")
    segments = String.split(canonical, ".")

    if Enum.any?(segments, &(&1 == "")) do
      {:error, :empty_segment}
    else
      {:ok, canonical}
    end
  end

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
