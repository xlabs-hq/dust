defmodule Dust.Instance do
  @moduledoc """
  Macro that generates a named Dust facade module from application config.

  ## Usage

      defmodule MyApp.Dust do
        use Dust, otp_app: :my_app
      end

  Then in your config:

      config :my_app, MyApp.Dust,
        stores: ["james/blog"],
        cache: {Dust.Cache.Memory, []},
        url: "ws://localhost:7755/ws/sync",
        token: "sk_..."

  And in your supervision tree:

      children = [
        MyApp.Dust
      ]

  The facade delegates all public API functions (get, put, delete, etc.)
  to `Dust.SyncEngine`, so `MyApp.Dust.get("james/blog", "key")` is
  equivalent to `Dust.get("james/blog", "key")`.

  ## Testing mode

  Set `testing: :manual` in config to skip starting the WebSocket connection:

      config :my_app, MyApp.Dust,
        stores: ["test/store"],
        cache: {Dust.Cache.Memory, []},
        testing: :manual
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      @otp_app unquote(otp_app)

      def child_spec(runtime_opts) do
        config = Application.fetch_env!(@otp_app, __MODULE__)
        merged = Keyword.merge(config, runtime_opts)

        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [merged]},
          type: :supervisor
        }
      end

      def start_link(runtime_opts \\ []) do
        config = Application.fetch_env!(@otp_app, __MODULE__)
        merged = Keyword.merge(config, runtime_opts)
        Dust.Supervisor.start_link(merged ++ [name: __MODULE__])
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
  end
end
