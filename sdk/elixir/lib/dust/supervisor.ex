defmodule Dust.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    stores = Keyword.fetch!(opts, :stores)
    cache = Keyword.fetch!(opts, :cache)
    _url = Keyword.get(opts, :url, "ws://localhost:7000/ws/sync")
    _token = Keyword.get(opts, :token, System.get_env("DUST_API_KEY"))

    engine_children =
      Enum.map(stores, fn store ->
        {Dust.SyncEngine, store: store, cache: cache}
      end)

    children =
      [
        {Registry, keys: :unique, name: Dust.SyncEngineRegistry},
        {Registry, keys: :unique, name: Dust.ConnectionRegistry}
      ] ++ engine_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end
