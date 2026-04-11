defmodule Dust.Protocol.Codec do
  @doc "Encode a map into the specified wire format."
  def encode(:msgpack, data) when is_map(data) do
    data
    |> stringify_keys()
    |> Msgpax.pack()
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  def encode(:json, data) when is_map(data) do
    Jason.encode(data)
  end

  @doc "Decode binary data from the specified wire format."
  def decode(:msgpack, binary) when is_binary(binary) do
    Msgpax.unpack(binary)
  end

  def decode(:json, binary) when is_binary(binary) do
    Jason.decode(binary)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
