defmodule Dust.Cache do
  @callback read(store :: String.t(), path :: String.t()) :: {:ok, term()} | :miss
  @callback read_all(store :: String.t(), pattern :: String.t()) :: [{String.t(), term()}]
  @callback write(store :: String.t(), path :: String.t(), value :: term(), type :: String.t(), seq :: integer()) :: :ok
  @callback write_batch(store :: String.t(), entries :: [{String.t(), term(), String.t(), integer()}]) :: :ok
  @callback delete(store :: String.t(), path :: String.t()) :: :ok
  @callback last_seq(store :: String.t()) :: integer()
end
