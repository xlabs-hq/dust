defmodule Dust.Supervisor do
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    stores = Keyword.fetch!(opts, :stores)
    testing = Keyword.get(opts, :testing)

    cache =
      if testing == :manual do
        Keyword.get(opts, :cache, {Dust.Cache.Memory, []})
      else
        Keyword.fetch!(opts, :cache)
      end

    url = Keyword.get(opts, :url, "ws://localhost:7755/ws/sync")
    token = Keyword.get(opts, :token, System.get_env("DUST_API_KEY"))
    device_id = Keyword.get(opts, :device_id)

    engine_children =
      Enum.map(stores, fn store ->
        {Dust.SyncEngine, store: store, cache: cache}
      end)

    connection_children =
      if testing == :manual do
        []
      else
        connection_opts =
          [
            url: url,
            token: token,
            device_id: device_id,
            stores: stores,
            name: Dust.Connection
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        [{Dust.Connection, connection_opts}]
      end

    registry_children =
      for {name, spec} <- [
            {Dust.SyncEngineRegistry,
             {Registry, keys: :unique, name: Dust.SyncEngineRegistry}},
            {Dust.ConnectionRegistry,
             {Registry, keys: :unique, name: Dust.ConnectionRegistry}}
          ],
          !Process.whereis(name),
          do: spec

    subscribers = Keyword.get(opts, :subscribers, [])

    subscriber_children =
      if subscribers == [] do
        []
      else
        [{Dust.SubscriberRegistrar, subscribers: subscribers}]
      end

    children =
      registry_children ++
        engine_children ++
        connection_children ++
        subscriber_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end
