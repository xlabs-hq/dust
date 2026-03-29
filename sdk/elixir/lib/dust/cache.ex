defmodule Dust.Cache do
  @callback read(target :: term(), store :: String.t(), path :: String.t()) :: {:ok, term()} | :miss
  @callback read_all(target :: term(), store :: String.t(), pattern :: String.t()) :: [{String.t(), term()}]
  @callback write(target :: term(), store :: String.t(), path :: String.t(), value :: term(), type :: String.t(), seq :: integer()) :: :ok
  @callback write_batch(target :: term(), store :: String.t(), entries :: list()) :: :ok
  @callback delete(target :: term(), store :: String.t(), path :: String.t()) :: :ok
  @callback last_seq(target :: term(), store :: String.t()) :: integer()
end
