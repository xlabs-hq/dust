defmodule DustProtocol.Path.LegacyDot do
  @moduledoc """
  Dotted-path helpers from the pre-segment-first capability version.

  This module is deliberately separate and visibly named so callers
  can be migrated one at a time to `DustProtocol.Path` (segment-first)
  without breaking the build. Once migration is complete, this module
  is deleted.

  **Do not use this module in new code.** If you're reading data on
  the wire from a new-capver client, use `DustProtocol.Path` instead.
  This module exists only to keep the in-flight migration moving.

  ## Legacy semantics (preserved here)

  - `.` is the segment separator.
  - `/` is accepted as an alias for `.` and gets normalized.
  - Segments cannot contain literal `.` or `/`. There is no escape.
  - Empty segments are invalid.

  These semantics make literal-dot keys (`example.com`, emails, file
  names with extensions) impossible — which is the headline reason
  segment-first paths replace them.
  """

  @doc """
  Normalize a dotted-or-slashed path into the canonical dotted form.
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
  Normalize a glob pattern (dotted or slashed) into canonical dotted
  form. `*` and `**` segments are valid.
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
  Build a canonical dotted path from a list of URL `*path` segments.
  Rejects any segment containing `.` (legacy ambiguity guard).
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
  @spec parse(binary()) :: {:ok, [binary()]} | {:error, atom()}
  def parse(""), do: {:error, :empty_path}

  def parse(path) when is_binary(path) do
    segments = String.split(path, ".")

    if Enum.any?(segments, &(&1 == "")) do
      {:error, :empty_segment}
    else
      {:ok, segments}
    end
  end

  @doc "Join a list of segments with dots."
  @spec to_string([binary()]) :: binary()
  def to_string(segments) when is_list(segments) do
    Enum.join(segments, ".")
  end
end
