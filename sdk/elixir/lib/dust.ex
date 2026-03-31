defmodule Dust do
  @moduledoc "Dust SDK — reactive global map client."

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Dust.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  defdelegate get(store, path), to: Dust.SyncEngine
  defdelegate put(store, path, value), to: Dust.SyncEngine
  defdelegate delete(store, path), to: Dust.SyncEngine
  defdelegate merge(store, path, map), to: Dust.SyncEngine
  defdelegate increment(store, path, delta \\ 1), to: Dust.SyncEngine
  defdelegate add(store, path, member), to: Dust.SyncEngine
  defdelegate remove(store, path, member), to: Dust.SyncEngine
  defdelegate put_file(store, path, source_path), to: Dust.SyncEngine
  defdelegate put_file(store, path, source_path, opts), to: Dust.SyncEngine
  defdelegate on(store, pattern, callback, opts \\ []), to: Dust.SyncEngine
  defdelegate enum(store, pattern), to: Dust.SyncEngine
  defdelegate status(store), to: Dust.SyncEngine
end
