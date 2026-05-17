defmodule Dust do
  @moduledoc "Dust SDK — reactive global map client."

  @cloud_url "wss://dustlayer.io/ws/sync"

  @doc """
  Returns the WebSocket URL for Dust's hosted cloud service at dustlayer.io.

  Use as the `:url` option when starting the supervisor against cloud:

      {Dust, stores: ["acme/site"], url: Dust.cloud_url(), token: token, cache: ...}
  """
  def cloud_url, do: @cloud_url

  defmacro __using__(opts) do
    quote do
      use Dust.Instance, unquote(opts)
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Dust.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  defdelegate get(store, path), to: Dust.SyncEngine
  defdelegate get_many(store, paths), to: Dust.SyncEngine
  defdelegate entry(store, path), to: Dust.SyncEngine
  defdelegate put(store, path, value), to: Dust.SyncEngine
  defdelegate put(store, path, value, opts), to: Dust.SyncEngine
  defdelegate delete(store, path), to: Dust.SyncEngine
  defdelegate delete(store, path, opts), to: Dust.SyncEngine
  defdelegate merge(store, path, map), to: Dust.SyncEngine
  defdelegate merge(store, path, map, opts), to: Dust.SyncEngine
  defdelegate increment(store, path, delta \\ 1), to: Dust.SyncEngine
  defdelegate increment(store, path, delta, opts), to: Dust.SyncEngine
  defdelegate add(store, path, member), to: Dust.SyncEngine
  defdelegate add(store, path, member, opts), to: Dust.SyncEngine
  defdelegate remove(store, path, member), to: Dust.SyncEngine
  defdelegate remove(store, path, member, opts), to: Dust.SyncEngine
  defdelegate put_file(store, path, source_path), to: Dust.SyncEngine
  defdelegate put_file(store, path, source_path, opts), to: Dust.SyncEngine
  defdelegate on(store, pattern, callback, opts \\ []), to: Dust.SyncEngine
  defdelegate watch(store, pattern, callback, opts \\ []), to: Dust.SyncEngine, as: :on
  defdelegate off(store, ref), to: Dust.SyncEngine
  defdelegate unsubscribe(store, ref), to: Dust.SyncEngine, as: :off
  defdelegate enum(store, pattern), to: Dust.SyncEngine
  defdelegate enum(store, pattern, opts), to: Dust.SyncEngine
  defdelegate range(store, from, to, opts \\ []), to: Dust.SyncEngine
  defdelegate status(store), to: Dust.SyncEngine
end
