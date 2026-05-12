defmodule Dust.Protocol.Path.LegacyDot do
  @moduledoc """
  Dotted-path helpers from the pre-segment-first capability version.

  Visibly named + separate so callers can be migrated one at a time
  without breaking the SDK build. Deleted at the end of the migration.

  Mirrors `DustProtocol.Path.LegacyDot` in the canonical package.
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

  @spec to_string([binary()]) :: binary()
  def to_string(segments) when is_list(segments) do
    Enum.join(segments, ".")
  end
end
