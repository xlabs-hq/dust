defmodule DustEcto.Transport do
  @moduledoc """
  Behaviour every dust_ecto transport adapter implements. Two
  implementations ship: `DustEcto.Transport.SDK` (recommended, uses
  Phoenix Channels via `:dust`) and `DustEcto.Transport.HTTP`
  (Req-based, stateless, no realtime).

  Repo functions never call adapters directly — they go through
  `DustEcto.Transport.pick/0` which returns the active adapter +
  config based on `dust_facade` config and the SyncEngineRegistry.
  """

  require Logger

  @default_base_url "https://dustlayer.io"

  @type store :: String.t()
  @type path :: String.t()
  @type pattern :: String.t()
  @type opts :: keyword()
  @type entry :: %{path: String.t(), value: term(), type: String.t(), revision: integer()}
  @type page :: %{items: [entry() | String.t()], next_cursor: String.t() | nil}

  @callback list(store, pattern, opts) :: {:ok, page()} | {:error, term()}
  @callback get(store, path) :: {:ok, entry()} | {:error, :not_found | term()}
  @callback exists?(store, path) :: {:ok, boolean()} | {:error, term()}

  @callback put(store, path, value :: term(), opts) ::
              {:ok, %{store_seq: integer()}} | {:error, term()}

  @callback delete(store, path, opts) ::
              {:ok, %{store_seq: integer()}} | {:error, term()}

  @callback batch_write(store, ops :: [map()], opts) ::
              {:ok, %{store_seq: integer(), ops: [map()]}} | {:error, term()}

  @callback subscribe(store, pattern, callback :: (map() -> any())) ::
              {:ok, reference()} | {:error, :not_supported | term()}

  @callback unsubscribe(store, ref :: reference()) :: :ok

  @doc """
  Picks the active transport at call time. Returns a `{module, config}`
  tuple where `config` carries adapter-specific data the Repo passes
  through (e.g. the SDK facade module name, or the HTTP base_url).

  Detection order:
    1. Explicit `config :dust_ecto, :dust_facade, MyApp.Dust` — SDK mode.
    2. `Dust.SyncEngineRegistry` has the configured store registered —
       SDK mode using the global `Dust` module.
    3. Otherwise — HTTP mode.

  This runs on every Repo call (cheap — one or two ETS lookups), so
  the same Elixir node can attach a `Dust.Supervisor` later and the
  transport picks it up without restart.
  """
  @spec pick() :: {module(), map()}
  def pick do
    cond do
      facade = Application.get_env(:dust_ecto, :dust_facade) ->
        {DustEcto.Transport.SDK, %{facade: facade}}

      sdk_registry_has_store?() ->
        {DustEcto.Transport.SDK, %{facade: Dust}}

      true ->
        warn_if_sdk_degraded()

        {DustEcto.Transport.HTTP,
         %{
           # base_url defaults to the canonical host — apps only need
           # to set this for staging environments or self-hosted Dust.
           # The token has no sensible default (it's a secret) so we
           # still hard-require it.
           base_url: Application.get_env(:dust_ecto, :base_url, @default_base_url),
           token: Application.fetch_env!(:dust_ecto, :token)
         }}
    end
  end

  # A running SyncEngineRegistry with no engine for the configured store
  # means the SDK transport was set up but its sync engine is down — the
  # HTTP fallback is a degradation, not a choice. Warn, throttled to once
  # a minute, so the silent ~100x slowdown shows up in logs. Plain HTTP
  # usage (no registry process at all) stays silent.
  @degraded_warn_interval_ms 60_000

  defp warn_if_sdk_degraded do
    store = Application.get_env(:dust_ecto, :store)

    if store && Process.whereis(Dust.SyncEngineRegistry) && warn_due?() do
      Logger.warning(
        "dust_ecto: sync engine for store #{inspect(store)} is not registered; " <>
          "falling back to the HTTP transport (slow, no realtime)"
      )
    end
  end

  defp warn_due? do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get({__MODULE__, :degraded_warned_at}, nil)

    if is_nil(last) or now - last >= @degraded_warn_interval_ms do
      :persistent_term.put({__MODULE__, :degraded_warned_at}, now)
      true
    else
      false
    end
  end

  defp sdk_registry_has_store? do
    case Process.whereis(Dust.SyncEngineRegistry) do
      nil ->
        false

      _ ->
        case Application.get_env(:dust_ecto, :store) do
          nil -> false
          store -> Registry.lookup(Dust.SyncEngineRegistry, store) != []
        end
    end
  end

  @doc "The configured default store name for Repo calls. Required."
  @spec store!() :: store()
  def store! do
    Application.fetch_env!(:dust_ecto, :store)
  end
end
