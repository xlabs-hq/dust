defmodule Dust.PubSubBridge do
  @moduledoc """
  Bridges Dust events to Phoenix.PubSub.

  When configured with a `:pubsub` option, registers a catch-all `**` callback
  on each store that broadcasts every event to the PubSub topic `"dust:{store}"`.

  Subscribers subscribe to the store topic and filter in `handle_info`:

      Phoenix.PubSub.subscribe(MyApp.PubSub, "dust:james/blog")

      def handle_info({:dust_event, event}, state) do
        # event is a map with :store, :path, :op, :value, etc.
      end
  """

  @doc "Register PubSub broadcasting for all configured stores."
  def register(pubsub, stores) do
    Enum.each(stores, fn store ->
      Dust.SyncEngine.on(store, "**", fn event ->
        Phoenix.PubSub.broadcast(pubsub, "dust:#{store}", {:dust_event, event})
      end)
    end)
  end
end
