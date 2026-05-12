defmodule DustEcto.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Holds a unique-key entry per active {schema, pubsub, topic}
      # broadcaster. Lookups are O(1) and the cost is negligible even
      # when no broadcasters are ever started.
      {Registry, keys: :unique, name: DustEcto.Phoenix.Registry},
      {DynamicSupervisor, name: DustEcto.Phoenix.BroadcasterSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DustEcto.Supervisor)
  end
end
