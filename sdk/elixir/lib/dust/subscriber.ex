defmodule Dust.Subscriber do
  @moduledoc """
  Declarative callback handler for Dust store events.

  Define a subscriber module to react to store changes matching a glob pattern:

      defmodule MyApp.PostSubscriber do
        use Dust.Subscriber,
          store: "myapp/data",
          pattern: "posts.*"

        @impl true
        def handle_event(event) do
          # event is a map with :store, :path, :op, :value, etc.
          IO.inspect(event, label: "post changed")
          :ok
        end
      end

  Then register it in your Dust config:

      config :my_app, MyApp.Dust,
        stores: ["myapp/data"],
        subscribers: [MyApp.PostSubscriber]

  ## Options

    * `:store` (required) - the store name to subscribe to
    * `:pattern` (required) - glob pattern for matching paths (e.g. `"posts.*"`)
    * `:max_queue_size` - maximum pending events before the subscription is
      dropped due to backpressure (default: `1000`)
  """

  @callback handle_event(event :: map()) :: :ok | {:error, term()}

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)
    pattern = Keyword.fetch!(opts, :pattern)
    max_queue_size = Keyword.get(opts, :max_queue_size, 1000)

    quote do
      @behaviour Dust.Subscriber

      def __dust_store__, do: unquote(store)
      def __dust_pattern__, do: unquote(pattern)
      def __dust_max_queue_size__, do: unquote(max_queue_size)

      def __dust_register__ do
        Dust.SyncEngine.on(
          __dust_store__(),
          __dust_pattern__(),
          fn event -> __MODULE__.handle_event(event) end,
          max_queue_size: __dust_max_queue_size__()
        )
      end
    end
  end
end
