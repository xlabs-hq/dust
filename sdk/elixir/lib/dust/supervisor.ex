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

    activity_name = Keyword.get(opts, :activity_buffer_name, Dust.ActivityBuffer)

    activity_children = [
      {Dust.ActivityBuffer, name: activity_name}
    ]

    engine_children =
      Enum.map(stores, fn store ->
        {Dust.SyncEngine, store: store, cache: cache, activity_buffer: activity_name}
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
    pubsub = Keyword.get(opts, :pubsub)

    registrar_opts =
      [subscribers: subscribers, pubsub: pubsub, stores: stores]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    subscriber_children =
      if subscribers == [] and is_nil(pubsub) do
        []
      else
        [{Dust.SubscriberRegistrar, registrar_opts}]
      end

    children =
      registry_children ++
        activity_children ++
        engine_children ++
        connection_children ++
        subscriber_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end
