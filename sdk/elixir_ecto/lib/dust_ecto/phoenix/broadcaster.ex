defmodule DustEcto.Phoenix.Broadcaster do
  @moduledoc """
  One broadcaster process per `{schema, pubsub, topic}` triple. Holds
  a single `DustEcto.Repo.subscribe/2` registration whose callback
  broadcasts every event through Phoenix.PubSub on `topic`.

  Lifecycle:
    * Started lazily by `DustEcto.Phoenix.subscribe_to_pubsub/3`.
    * Registered in `DustEcto.Phoenix.Registry` keyed by
      `{schema, pubsub, topic}` so concurrent callers reuse the same
      broadcaster.
    * Stays alive for the application lifetime. The cost is one
      process and one entry in the SDK callback registry — both
      negligible. Cleanup is opt-in (caller can `unsubscribe/3`).

  The broadcast message shape is `{:dust_event, event}` where `event`
  is whatever `DustEcto.Repo.subscribe/2` would deliver:
  `{:upserted, struct}` or `{:deleted, slug}`.
  """

  use GenServer

  require Logger

  @doc false
  def start_link({schema, pubsub, topic} = key)
      when is_atom(schema) and is_atom(pubsub) and is_binary(topic) do
    GenServer.start_link(__MODULE__, key, name: via(key))
  end

  @doc false
  def via({schema, pubsub, topic}) do
    {:via, Registry, {DustEcto.Phoenix.Registry, {schema, pubsub, topic}}}
  end

  @impl true
  def init({schema, pubsub, topic}) do
    case DustEcto.Repo.subscribe(schema, broadcast_callback(pubsub, topic)) do
      {:ok, ref} ->
        {:ok, %{schema: schema, pubsub: pubsub, topic: topic, ref: ref}}

      {:error, %DustEcto.Error{} = err} ->
        {:stop, {:dust_subscribe_failed, err}}
    end
  end

  @impl true
  def terminate(_reason, %{ref: ref}) when is_reference(ref) do
    DustEcto.Repo.unsubscribe(ref)
    :ok
  end

  def terminate(_, _), do: :ok

  # Returns a 1-arity function suitable for DustEcto.Repo.subscribe/2.
  # We deliberately use apply/3 rather than a direct Phoenix.PubSub
  # call so this module compiles even when phoenix_pubsub isn't a
  # transitive dep — the call only ever runs if the broadcaster
  # started, which in turn requires phoenix_pubsub at runtime.
  defp broadcast_callback(pubsub, topic) do
    fn event ->
      apply(Phoenix.PubSub, :broadcast, [pubsub, topic, {:dust_event, event}])
    end
  end
end
