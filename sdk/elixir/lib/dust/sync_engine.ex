defmodule Dust.SyncEngine do
  use GenServer

  defstruct [:store, :cache, :cache_pid, :callbacks, :pending_ops, :status, :last_store_seq]

  def start_link(opts) do
    store = Keyword.fetch!(opts, :store)
    GenServer.start_link(__MODULE__, opts, name: via(store))
  end

  def via(store), do: {:via, Registry, {Dust.SyncEngineRegistry, store}}

  def get(store, path) do
    GenServer.call(via(store), {:get, path})
  end

  def put(store, path, value) do
    GenServer.call(via(store), {:put, path, value})
  end

  def delete(store, path) do
    GenServer.call(via(store), {:delete, path})
  end

  def merge(store, path, map) do
    GenServer.call(via(store), {:merge, path, map})
  end

  def enum(store, pattern) do
    GenServer.call(via(store), {:enum, pattern})
  end

  def status(store) do
    GenServer.call(via(store), :status)
  end

  def on(store, pattern, callback) do
    GenServer.call(via(store), {:on, pattern, callback})
  end

  def handle_server_event(store, event) do
    GenServer.cast(via(store), {:server_event, event})
  end

  def set_status(store, new_status) do
    GenServer.cast(via(store), {:set_status, new_status})
  end

  # Server

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    {cache_mod, cache_opts} = Keyword.fetch!(opts, :cache)

    cache_pid =
      case cache_opts do
        opts when is_list(opts) ->
          {:ok, pid} = cache_mod.start_link(opts)
          pid
        pid when is_pid(pid) ->
          pid
      end

    callbacks = Dust.CallbackRegistry.new()
    last_seq = cache_mod.last_seq(cache_pid, store)

    state = %__MODULE__{
      store: store,
      cache: cache_mod,
      cache_pid: cache_pid,
      callbacks: callbacks,
      pending_ops: %{},
      status: :disconnected,
      last_store_seq: last_seq
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get, path}, _from, state) do
    result = state.cache.read(state.cache_pid, state.store, path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:put, path, value}, _from, state) do
    client_op_id = generate_op_id()
    type = detect_type(value)

    # Optimistic local write
    :ok = state.cache.write(state.cache_pid, state.store, path, value, type, 0)

    # Fire local callbacks
    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :set, value: value,
      committed: false, source: :local, client_op_id: client_op_id
    })

    # Queue for server
    pending = Map.put(state.pending_ops, client_op_id, %{op: :set, path: path, value: value})
    state = %{state | pending_ops: pending}

    # Notify connection to send
    send_to_connection(state.store, %{
      op: :set, path: path, value: value, client_op_id: client_op_id
    })

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, path}, _from, state) do
    client_op_id = generate_op_id()

    state.cache.delete(state.cache_pid, state.store, path)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :delete, value: nil,
      committed: false, source: :local, client_op_id: client_op_id
    })

    pending = Map.put(state.pending_ops, client_op_id, %{op: :delete, path: path})
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, %{op: :delete, path: path, client_op_id: client_op_id})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:merge, path, map}, _from, state) do
    client_op_id = generate_op_id()

    # Optimistic: write each child
    Enum.each(map, fn {key, value} ->
      child_path = "#{path}.#{key}"
      state.cache.write(state.cache_pid, state.store, child_path, value, detect_type(value), 0)
    end)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :merge, value: map,
      committed: false, source: :local, client_op_id: client_op_id
    })

    pending = Map.put(state.pending_ops, client_op_id, %{op: :merge, path: path, value: map})
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, %{op: :merge, path: path, value: map, client_op_id: client_op_id})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:enum, pattern}, _from, state) do
    results = state.cache.read_all(state.cache_pid, state.store, pattern)
    {:reply, results, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connection: state.status,
      last_store_seq: state.last_store_seq,
      pending_ops: map_size(state.pending_ops)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call({:on, pattern, callback}, _from, state) do
    ref = Dust.CallbackRegistry.register(state.callbacks, state.store, pattern, callback)
    {:reply, ref, state}
  end

  @impl true
  def handle_cast({:set_status, new_status}, state) do
    {:noreply, %{state | status: new_status}}
  end

  @impl true
  def handle_cast({:server_event, event}, state) do
    client_op_id = event["client_op_id"]
    path = event["path"]
    store_seq = event["store_seq"]
    op = String.to_existing_atom(event["op"])
    value = event["value"]

    # Update cache with canonical state
    case op do
      :set ->
        state.cache.write(state.cache_pid, state.store, path, value, detect_type(value), store_seq)
      :delete ->
        state.cache.delete(state.cache_pid, state.store, path)
      :merge when is_map(value) ->
        Enum.each(value, fn {key, v} ->
          child_path = "#{path}.#{key}"
          state.cache.write(state.cache_pid, state.store, child_path, v, detect_type(v), store_seq)
        end)
    end

    # Reconcile pending ops
    was_pending = Map.has_key?(state.pending_ops, client_op_id)
    pending = Map.delete(state.pending_ops, client_op_id)

    # If this was our own write accepted as-is, don't fire callback again
    unless was_pending do
      dispatch_callbacks(state, path, %{
        store: state.store, path: path, op: op, value: value,
        store_seq: store_seq, committed: true, source: :server,
        device_id: event["device_id"], client_op_id: client_op_id
      })
    end

    state = %{state | pending_ops: pending, last_store_seq: store_seq}
    {:noreply, state}
  end

  defp dispatch_callbacks(state, path, event) do
    callbacks = Dust.CallbackRegistry.match(state.callbacks, state.store, path)
    Enum.each(callbacks, fn callback -> callback.(event) end)
  end

  defp send_to_connection(store, op_attrs) do
    case GenServer.whereis(Dust.Connection) do
      nil -> :ok
      pid -> send(pid, {:send_write, store, op_attrs})
    end
  end

  defp generate_op_id do
    "op_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp detect_type(value) when is_boolean(value), do: "boolean"
  defp detect_type(value) when is_map(value), do: "map"
  defp detect_type(value) when is_binary(value), do: "string"
  defp detect_type(value) when is_integer(value), do: "integer"
  defp detect_type(value) when is_float(value), do: "float"
  defp detect_type(nil), do: "null"
  defp detect_type(_), do: "string"
end
