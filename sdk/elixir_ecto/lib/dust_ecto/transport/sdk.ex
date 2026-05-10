defmodule DustEcto.Transport.SDK do
  @moduledoc """
  WebSocket-backed transport — delegates every call to the configured
  Dust facade module (default `Dust`). Uses the SDK pre-work landed in
  the same monorepo: sync write semantics on every op, subtree-aware
  reads, and `:committed` subscription mode for exactly-once delivery.

  Returns:

    * `{:ok, ...}` shapes match the Repo contract — `%{store_seq:}` for
      writes, full entry maps for reads.
    * `{:error, %DustEcto.Error{}}` for everything that's not a 2xx
      analogue. Network-shaped failures from the SDK (e.g. `:timeout`)
      get translated to the right `kind`.

  All callbacks are documented on `DustEcto.Transport`.
  """

  @behaviour DustEcto.Transport

  alias DustEcto.Error

  @impl DustEcto.Transport
  def list(store, pattern, opts) do
    config = pop_config(opts)
    facade = facade!(config)

    page_opts =
      opts
      |> Keyword.drop([:config])
      |> Keyword.put_new(:select, :entries)

    case safe_call(fn -> facade.enum(store, pattern, page_opts) end) do
      %Dust.Page{items: items, next_cursor: cursor} ->
        {:ok, %{items: Enum.map(items, &render_item/1), next_cursor: cursor}}

      items when is_list(items) ->
        # The 2-arg `enum/2` legacy shape returns [{path, value}, ...].
        # Repo always passes opts so this branch is rare, but we handle it.
        {:ok, %{items: Enum.map(items, &render_item/1), next_cursor: nil}}

      {:error, %Error{}} = err ->
        err
    end
  end

  @impl DustEcto.Transport
  def get(store, path) do
    config = pop_config([])
    facade = facade!(config)

    case safe_call(fn -> facade.entry(store, path) end) do
      {:ok, %Dust.Entry{path: p, value: v, type: t, revision: r}} ->
        {:ok, %{path: p, value: v, type: t, revision: r}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Error{}} = err ->
        err
    end
  end

  @impl DustEcto.Transport
  def exists?(store, path) do
    case get(store, path) do
      {:ok, _} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      err -> err
    end
  end

  @impl DustEcto.Transport
  def put(store, path, value, opts) do
    config = pop_config(opts)
    facade = facade!(config)
    sdk_opts = Keyword.drop(opts, [:config])

    translate_write_result(safe_call(fn -> facade.put(store, path, value, sdk_opts) end))
  end

  @impl DustEcto.Transport
  def delete(store, path, opts) do
    config = pop_config(opts)
    facade = facade!(config)
    sdk_opts = Keyword.drop(opts, [:config])

    translate_write_result(safe_call(fn -> facade.delete(store, path, sdk_opts) end))
  end

  defp translate_write_result({:ok, store_seq}) when is_integer(store_seq),
    do: {:ok, %{store_seq: store_seq}}

  defp translate_write_result({:ok, %{store_seq: _} = ok}),
    do: {:ok, ok}

  defp translate_write_result({:error, %Error{}} = err), do: err

  defp translate_write_result({:error, reason}) when is_atom(reason),
    do: {:error, sdk_error_to_dust(reason)}

  defp translate_write_result({:error, reason}) when is_binary(reason),
    do: {:error, sdk_error_to_dust(reason)}

  @impl DustEcto.Transport
  def batch_write(_store, _ops, _opts) do
    # Atomic batch is HTTP-only for now. The SDK protocol does not yet
    # expose a batch_write op; users wanting transactional multi-key
    # writes from SDK mode should construct individual ops or fall
    # back to HTTP. Tracked as future work.
    {:error,
     Error.new(
       :not_supported,
       "batch_write is not available over the SDK transport — use HTTP mode for atomic multi-key writes",
       retryable?: false
     )}
  end

  @impl DustEcto.Transport
  def subscribe(store, pattern, callback) do
    config = pop_config([])
    facade = facade!(config)

    case safe_call(fn -> facade.on(store, pattern, callback, mode: :committed) end) do
      ref when is_reference(ref) -> {:ok, ref}
      {:error, %Error{}} = err -> err
    end
  end

  @impl DustEcto.Transport
  def unsubscribe(store, ref) do
    config = pop_config([])
    facade = facade!(config)

    _ = safe_call(fn -> facade.off(store, ref) end)
    :ok
  end

  # --- internals ---

  defp pop_config(opts) do
    Keyword.get(opts, :config) ||
      case DustEcto.Transport.pick() do
        {DustEcto.Transport.SDK, config} -> config
        _ -> %{facade: Dust}
      end
  end

  defp facade!(%{facade: f}) when is_atom(f), do: f
  defp facade!(_), do: Dust

  # Wrap an SDK call. On normal completion returns the raw SDK result
  # untouched (so callers can pattern-match on whatever shape the SDK
  # returned). On `:exit` (process down, timeout) returns
  # `{:error, %DustEcto.Error{}}` instead.
  defp safe_call(fun) do
    fun.()
  catch
    :exit, {reason, _} when reason in [:timeout, :noproc, :normal] ->
      {:error, sdk_error_to_dust(reason)}

    :exit, reason ->
      {:error, Error.new(:network, {:sdk_exit, reason}, retryable?: true)}
  end

  defp sdk_error_to_dust(:conflict), do: Error.new(:conflict, nil)
  defp sdk_error_to_dust(:timeout), do: Error.new(:timeout, "no ack within window")
  defp sdk_error_to_dust(:rate_limited), do: Error.new(:rate_limited, nil)
  defp sdk_error_to_dust(:unauthorized), do: Error.new(:unauthorized, nil)

  defp sdk_error_to_dust(:noproc),
    do: Error.new(:network, "Dust SDK process not running", retryable?: true)

  defp sdk_error_to_dust(:normal),
    do: Error.new(:network, "Dust SDK process exited", retryable?: true)

  defp sdk_error_to_dust("conflict"), do: Error.new(:conflict, nil)
  defp sdk_error_to_dust("rate_limited"), do: Error.new(:rate_limited, nil)
  defp sdk_error_to_dust("unauthorized"), do: Error.new(:unauthorized, nil)

  defp sdk_error_to_dust(other),
    do: Error.new(:invalid_params, other, retryable?: false)

  defp render_item(%Dust.Entry{path: p, value: v, type: t, revision: r}),
    do: %{path: p, value: v, type: t, revision: r}

  defp render_item({path, value}) when is_binary(path),
    do: %{path: path, value: value, type: nil, revision: nil}

  defp render_item(path) when is_binary(path), do: path
end
