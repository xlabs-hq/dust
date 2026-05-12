defmodule Dust.Sync.ValueCodec do
  @moduledoc """
  Encodes and decodes values for storage in jsonb columns.

  StoreEntry.value is a :map column, so scalars, Decimals, and DateTimes
  are wrapped in envelope maps for lossless round-tripping through jsonb.
  """

  # --- Wrapping (Elixir values → jsonb-safe maps) ---

  def wrap(%Decimal{} = d), do: %{"_typed" => Decimal.to_string(d), "_type" => "decimal"}
  def wrap(%DateTime{} = dt), do: %{"_typed" => DateTime.to_iso8601(dt), "_type" => "datetime"}
  def wrap(value) when is_map(value), do: value
  def wrap(value), do: %{"_scalar" => value}

  # --- Unwrapping (jsonb maps → Elixir values) ---

  def unwrap(%{"_typed" => v, "_type" => "decimal"}), do: Decimal.new(v)

  def unwrap(%{"_typed" => v, "_type" => "datetime"}) do
    {:ok, dt, _} = DateTime.from_iso8601(v)
    dt
  end

  def unwrap(%{"_scalar" => scalar}), do: scalar
  def unwrap(nil), do: nil
  def unwrap(value), do: value

  # --- Specialized unwrappers ---

  def unwrap_set(%{"_scalar" => list}) when is_list(list), do: list
  def unwrap_set(%{"_scalar" => _}), do: []
  def unwrap_set(nil), do: []
  def unwrap_set(_), do: []

  # --- Type detection ---

  def detect_type(%Decimal{}), do: "decimal"
  def detect_type(%DateTime{}), do: "datetime"
  def detect_type(value) when is_map(value), do: "map"
  def detect_type(value) when is_binary(value), do: "string"
  def detect_type(value) when is_integer(value), do: "integer"
  def detect_type(value) when is_float(value), do: "float"
  def detect_type(value) when is_boolean(value), do: "boolean"
  def detect_type(nil), do: "null"
  def detect_type(_), do: "string"

  # --- Map expansion ---

  @doc """
  Recursively flatten a map into `{rendered_path, leaf_value}` pairs.

  `prefix` is a rendered slash path. Children are constructed via
  `DustProtocol.Path.child/2` so map keys containing literal `.` or
  `/` survive intact (rendered with `~0`/`~1` escapes by
  `Path.render/1`).
  """
  def flatten_map(prefix, map) when is_binary(prefix) and is_map(map) do
    {:ok, prefix_segments} = DustProtocol.Path.parse_rendered(prefix)
    do_flatten_map(prefix_segments, map)
  end

  defp do_flatten_map(prefix_segments, map) when is_list(prefix_segments) and is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      key_str = to_string(key)
      {:ok, child_segments} = DustProtocol.Path.child(prefix_segments, key_str)

      if is_map(value) and not typed_value?(value) do
        do_flatten_map(child_segments, value)
      else
        {:ok, child_path} = DustProtocol.Path.render(child_segments)
        [{child_path, value}]
      end
    end)
  end

  @doc "Check if a value is a typed envelope (file ref, Decimal, DateTime) that should not be expanded."
  def typed_value?(%{"_type" => "file"}), do: true
  def typed_value?(%{"_typed" => _, "_type" => _}), do: true
  def typed_value?(%Decimal{}), do: true
  def typed_value?(%DateTime{}), do: true
  def typed_value?(_), do: false
end
