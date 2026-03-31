defmodule Dust.Testing do
  @moduledoc """
  Test helpers for applications that use Dust.
  In :manual test mode, Dust uses a memory cache and no server connection.
  Use these functions to control Dust state in tests.
  """

  @doc "Populate the cache with known state. get/enum will return this data."
  def seed(store, entries) when is_map(entries) do
    Enum.each(entries, fn {path, value} ->
      type = detect_type(value)
      Dust.SyncEngine.seed_entry(store, path, value, type)
    end)

    :ok
  end

  @doc "Fire an event through the subscriber pipeline as if the server sent it. Synchronous."
  def emit(store, path, opts \\ []) do
    op = Keyword.get(opts, :op, :set)
    value = Keyword.get(opts, :value)
    meta = Keyword.get(opts, :meta, %{})

    event =
      %{
        "store" => store,
        "path" => path,
        "op" => to_string(op),
        "value" => value,
        "store_seq" => System.unique_integer([:positive]),
        "device_id" => "test",
        "client_op_id" => "test_#{System.unique_integer([:positive])}"
      }
      |> Map.merge(if meta != %{}, do: %{"meta" => meta}, else: %{})

    Dust.SyncEngine.handle_server_event(store, event)
    :ok
  end

  @doc "Control what Dust.status/1 returns."
  def set_status(store, connection_status, opts \\ []) do
    store_seq = Keyword.get(opts, :store_seq, 0)
    Dust.SyncEngine.set_status(store, connection_status)

    if store_seq > 0 do
      Dust.SyncEngine.set_store_seq(store, store_seq)
    end

    :ok
  end

  @doc "Build an event map for testing subscriber modules in isolation."
  def build_event(store, path, opts \\ []) do
    %{
      store: store,
      path: path,
      op: Keyword.get(opts, :op, :set),
      value: Keyword.get(opts, :value),
      store_seq: Keyword.get(opts, :store_seq, 1),
      committed: true,
      source: :server,
      device_id: "test",
      client_op_id: "test"
    }
  end

  defp detect_type(v) when is_boolean(v), do: "boolean"
  defp detect_type(v) when is_map(v), do: "map"
  defp detect_type(v) when is_binary(v), do: "string"
  defp detect_type(v) when is_integer(v), do: "integer"
  defp detect_type(v) when is_float(v), do: "float"
  defp detect_type(nil), do: "null"
  defp detect_type(_), do: "string"
end
