defmodule Dust.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    stores = Keyword.fetch!(opts, :stores)
    cache = Keyword.fetch!(opts, :cache)
    url = Keyword.get(opts, :url, "ws://localhost:7755/ws/sync")
    token = Keyword.get(opts, :token, System.get_env("DUST_API_KEY"))
    device_id = Keyword.get(opts, :device_id)

    engine_children =
      Enum.map(stores, fn store ->
        {Dust.SyncEngine, store: store, cache: cache}
      end)

    connection_opts =
      [
        url: url,
        token: token,
        device_id: device_id,
        stores: stores,
        name: Dust.Connection
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    children =
      [
        {Registry, keys: :unique, name: Dust.SyncEngineRegistry},
        {Registry, keys: :unique, name: Dust.ConnectionRegistry}
      ] ++
        engine_children ++
        [
          {Dust.Connection, connection_opts}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
