defmodule DustProtocol.Path do
  @moduledoc """
  Path utilities. Dust paths are dot-separated hierarchies, e.g.
  `"projects.alpha.title"`. For ergonomics (and REST URL convention),
  forward slashes are accepted everywhere as aliases for dots — so
  `"projects/alpha/title"` normalises to the same canonical form.

  Path segments cannot be empty and cannot themselves contain `.` or
  `/` after normalisation. There is no escape — keys with literal
  dots in their names are not supported.
  """

  @doc """
  Normalize a dotted-or-slashed path into the canonical dotted form.

  Accepts either separator or a mix. Validates that no segment is empty.
  """
  @spec normalize(binary()) :: {:ok, binary()} | {:error, atom()}
  def normalize(""), do: {:error, :empty_path}

  def normalize(path) when is_binary(path) do
    canonical = String.replace(path, "/", ".")

    case parse(canonical) do
      {:ok, _segments} -> {:ok, canonical}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Normalize a glob pattern. Same rules as `normalize/1`, but `*` and
  `**` segments are valid (and stay valid through the round-trip).
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

  @doc """
  Build a canonical path from a list of URL path segments (as captured
  by Phoenix `*path` glob routes). Rejects any segment containing `.`
  to avoid the `feature/beta/enabled` vs `feature.beta.enabled`
  ambiguity at the URL boundary — the wire form is dotted, the URL
  form is slashed, and the two must map injectively.
  """
  @spec from_url_segments([binary()]) :: {:ok, binary()} | {:error, atom()}
  def from_url_segments([]), do: {:error, :empty_path}

  def from_url_segments(segments) when is_list(segments) do
    cond do
      Enum.any?(segments, &(&1 == "")) ->
        {:error, :empty_segment}

      Enum.any?(segments, &String.contains?(&1, ".")) ->
        {:error, :dot_in_segment}

      true ->
        {:ok, Enum.join(segments, ".")}
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
