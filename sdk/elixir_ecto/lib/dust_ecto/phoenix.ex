defmodule DustEcto.Phoenix do
  @moduledoc """
  `Phoenix.PubSub` bridge for `DustEcto.Repo` subscriptions. Turns the
  four-step "supervise Dust, configure facade, subscribe in mount,
  don't block in the callback" recipe into a one-liner that's safe to
  call from a LiveView.

  ## Why

  `DustEcto.Repo.subscribe/2` invokes its callback inside the SDK's
  per-store sync engine process. If the callback blocks — and any
  realistic LiveView callback might — the engine blocks, freezing
  every subscriber on that store. The standard workaround is to
  capture `self()` and `send/2` from the callback, plus
  unsubscribe-on-terminate. That's a lot of boilerplate.

  `Phoenix.PubSub` already solves "fan out a message to many
  subscribers without blocking the broadcaster." This module wires
  the two together: one shared broadcaster per topic translates Dust
  events into PubSub broadcasts, and LiveViews subscribe to the
  PubSub topic as they normally would.

  ## Usage

      defmodule MyAppWeb.LinksLive do
        use MyAppWeb, :live_view
        alias MyApp.Reading.Link

        def mount(_, _, socket) do
          if connected?(socket) do
            :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, MyApp.PubSub, "links")
          end

          {:ok, assign(socket, links: load_links())}
        end

        def handle_info({:dust_event, {:upserted, %Link{} = link}}, socket),
          do: {:noreply, update(socket, :links, &upsert_by_slug(&1, link))}

        def handle_info({:dust_event, {:deleted, slug}}, socket),
          do: {:noreply, update(socket, :links, &delete_by_slug(&1, slug))}
      end

  No `terminate/2` cleanup needed — `Phoenix.PubSub` monitors
  subscribers and unsubscribes them automatically when they die. The
  broadcaster process stays alive for the application lifetime and is
  shared across every LiveView subscribed to the same topic.

  ## Requirements

  Needs the `phoenix_pubsub` package and an active SDK transport
  (i.e. `Dust.Supervisor` running in your supervision tree, or
  `config :dustlayer_ecto, :dust_facade, MyApp.Dust`). From HTTP mode the
  underlying `Repo.subscribe/2` returns `:not_supported`, which
  surfaces here as a `%DustEcto.Error{kind: :not_supported}`.
  """

  alias DustEcto.Error
  alias DustEcto.Phoenix.Broadcaster

  @typedoc """
  Message shape delivered to subscribers: `{:dust_event, event}` where
  `event` matches `DustEcto.Repo.subscribe/2`'s callback contract.
  """
  @type message :: {:dust_event, {:upserted, struct()} | {:deleted, String.t()}}

  @doc """
  Ensures a broadcaster is running for `{schema, pubsub, topic}` and
  subscribes the calling process to `pubsub` on `topic`.

  Idempotent — calling this from many LiveViews with the same triple
  shares a single broadcaster.

  Returns `:ok` on success, `{:error, %DustEcto.Error{}}` if
  `phoenix_pubsub` isn't loaded or the underlying `Repo.subscribe/2`
  failed (most commonly: HTTP transport).
  """
  @spec subscribe_to_pubsub(module(), atom(), String.t()) ::
          :ok | {:error, Error.t()}
  def subscribe_to_pubsub(schema, pubsub, topic)
      when is_atom(schema) and is_atom(pubsub) and is_binary(topic) do
    with :ok <- ensure_phoenix_pubsub_loaded(),
         {:ok, _pid} <- ensure_broadcaster(schema, pubsub, topic) do
      apply(Phoenix.PubSub, :subscribe, [pubsub, topic])
    end
  end

  @doc """
  Unsubscribes the calling process from `pubsub` on `topic`. Does not
  stop the broadcaster — siblings on the same topic keep receiving
  events. To stop the broadcaster entirely (rare; saves one process),
  use `stop_broadcaster/3`.
  """
  @spec unsubscribe_from_pubsub(atom(), String.t()) :: :ok
  def unsubscribe_from_pubsub(pubsub, topic)
      when is_atom(pubsub) and is_binary(topic) do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      apply(Phoenix.PubSub, :unsubscribe, [pubsub, topic])
    else
      :ok
    end
  end

  @doc """
  Stops the broadcaster for `{schema, pubsub, topic}`. Existing PubSub
  subscribers stop receiving updates immediately. Idempotent — no-op
  if the broadcaster isn't running.
  """
  @spec stop_broadcaster(module(), atom(), String.t()) :: :ok
  def stop_broadcaster(schema, pubsub, topic) do
    case Registry.lookup(DustEcto.Phoenix.Registry, {schema, pubsub, topic}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(DustEcto.Phoenix.BroadcasterSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  defp ensure_phoenix_pubsub_loaded do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      :ok
    else
      {:error,
       Error.new(
         :not_supported,
         "phoenix_pubsub is not loaded; add {:phoenix_pubsub, \"~> 2.0\"} to your deps",
         retryable?: false
       )}
    end
  end

  defp ensure_broadcaster(schema, pubsub, topic) do
    key = {schema, pubsub, topic}

    case Registry.lookup(DustEcto.Phoenix.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               DustEcto.Phoenix.BroadcasterSupervisor,
               {Broadcaster, key}
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, {:dust_subscribe_failed, %Error{} = err}} ->
            {:error, err}

          {:error, reason} ->
            {:error,
             Error.new(:http, "broadcaster start failed: #{inspect(reason)}", retryable?: false)}
        end
    end
  end
end
