defmodule Dust.SyncEngine do
  use GenServer

  defstruct [:store, :cache, :cache_target, :callbacks, :pending_ops, :status, :last_store_seq, :catch_up_seq, :activity_buffer]

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

  def increment(store, path, delta \\ 1) do
    GenServer.call(via(store), {:increment, path, delta})
  end

  def add(store, path, member) do
    GenServer.call(via(store), {:add, path, member})
  end

  def remove(store, path, member) do
    GenServer.call(via(store), {:remove, path, member})
  end

  def put_file(store, path, source_path, opts \\ []) do
    GenServer.call(via(store), {:put_file, path, source_path, opts})
  end

  def enum(store, pattern) do
    GenServer.call(via(store), {:enum, pattern})
  end

  def status(store) do
    GenServer.call(via(store), :status)
  end

  def on(store, pattern, callback, opts \\ []) do
    GenServer.call(via(store), {:on, pattern, callback, opts})
  end

  def handle_server_event(store, event) do
    GenServer.cast(via(store), {:server_event, event})
  end

  def set_status(store, new_status) do
    GenServer.cast(via(store), {:set_status, new_status})
  end

  def handle_write_rejected(store, client_op_id, reason) do
    GenServer.cast(via(store), {:write_rejected, client_op_id, reason})
  end

  def set_catch_up_complete(store, through_seq) do
    GenServer.cast(via(store), {:catch_up_complete, through_seq})
  end

  def handle_snapshot(store, snapshot) do
    GenServer.cast(via(store), {:snapshot, snapshot})
  end

  @doc "Write directly to cache without the write pipeline. For test seeding only."
  def seed_entry(store, path, value, type) do
    GenServer.call(via(store), {:seed_entry, path, value, type})
  end

  @doc "Update last_store_seq in state. For test harness only."
  def set_store_seq(store, seq) do
    GenServer.cast(via(store), {:set_store_seq, seq})
  end

  # Server

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    {cache_mod, cache_opts} = Keyword.fetch!(opts, :cache)

    cache_target =
      case cache_opts do
        opts when is_list(opts) ->
          {:ok, pid} = cache_mod.start_link(opts)
          pid

        pid when is_pid(pid) ->
          pid

        module when is_atom(module) ->
          # Stateless adapter (e.g., Ecto) — the target is the module itself (a Repo)
          module
      end

    callbacks = Dust.CallbackRegistry.new()
    last_seq = cache_mod.last_seq(cache_target, store)
    activity_buffer = Keyword.get(opts, :activity_buffer)

    state = %__MODULE__{
      store: store,
      cache: cache_mod,
      cache_target: cache_target,
      callbacks: callbacks,
      pending_ops: %{},
      status: :disconnected,
      last_store_seq: last_seq,
      activity_buffer: activity_buffer
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get, path}, _from, state) do
    result = state.cache.read(state.cache_target, state.store, path)

    result =
      case result do
        {:ok, %{"_type" => "file"} = map} -> {:ok, Dust.FileRef.from_map(map)}
        other -> other
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:put, path, value}, _from, state) do
    client_op_id = generate_op_id()
    type = detect_type(value)

    # Save previous value for rollback on rejection
    prev = state.cache.read(state.cache_target, state.store, path)

    # Optimistic local write
    :ok = state.cache.write(state.cache_target, state.store, path, value, type, 0)

    # Fire local callbacks
    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :set, value: value,
      committed: false, source: :local, client_op_id: client_op_id
    })

    # Queue for server (with prev_value for rollback)
    op_msg = %{op: :set, path: path, value: value, client_op_id: client_op_id, prev: prev}
    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    state = %{state | pending_ops: pending}

    # Notify connection to send
    send_to_connection(state.store, op_msg)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, path}, _from, state) do
    client_op_id = generate_op_id()

    state.cache.delete(state.cache_target, state.store, path)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :delete, value: nil,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg = %{op: :delete, path: path, client_op_id: client_op_id}
    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, op_msg)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:merge, path, map}, _from, state) do
    client_op_id = generate_op_id()

    # Optimistic: write each child
    Enum.each(map, fn {key, value} ->
      child_path = "#{path}.#{key}"
      state.cache.write(state.cache_target, state.store, child_path, value, detect_type(value), 0)
    end)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :merge, value: map,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg = %{op: :merge, path: path, value: map, client_op_id: client_op_id}
    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, op_msg)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:increment, path, delta}, _from, state) do
    client_op_id = generate_op_id()

    # Optimistic: read current value and add delta
    current =
      case state.cache.read(state.cache_target, state.store, path) do
        {:ok, val} when is_number(val) -> val
        _ -> 0
      end

    new_value = current + delta
    :ok = state.cache.write(state.cache_target, state.store, path, new_value, "counter", 0)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :increment, value: delta,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg = %{op: :increment, path: path, value: delta, client_op_id: client_op_id}
    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, op_msg)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add, path, member}, _from, state) do
    client_op_id = generate_op_id()

    # Optimistic: read current set and add member
    current_set =
      case state.cache.read(state.cache_target, state.store, path) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    new_set = Enum.uniq([member | current_set])
    :ok = state.cache.write(state.cache_target, state.store, path, new_set, "set", 0)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :add, value: member,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg = %{op: :add, path: path, value: member, client_op_id: client_op_id}
    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, op_msg)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove, path, member}, _from, state) do
    client_op_id = generate_op_id()

    # Optimistic: read current set and remove member
    current_set =
      case state.cache.read(state.cache_target, state.store, path) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    new_set = List.delete(current_set, member)
    :ok = state.cache.write(state.cache_target, state.store, path, new_set, "set", 0)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :remove, value: member,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg = %{op: :remove, path: path, value: member, client_op_id: client_op_id}
    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, op_msg)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:put_file, path, source_path, opts}, _from, state) do
    client_op_id = generate_op_id()

    # Read file and encode
    content = File.read!(source_path)
    base64_content = Base.encode64(content)
    filename = opts[:filename] || Path.basename(source_path)
    content_type = opts[:content_type] || "application/octet-stream"

    # Build optimistic file reference (we know the hash before upload)
    hash = "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))

    ref = %{
      "_type" => "file",
      "hash" => hash,
      "size" => byte_size(content),
      "content_type" => content_type,
      "filename" => filename,
      "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Optimistic local write (store the reference)
    :ok = state.cache.write(state.cache_target, state.store, path, ref, "file", 0)

    # Fire local callback
    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :put_file, value: ref,
      committed: false, source: :local, client_op_id: client_op_id
    })

    # Queue for server (connection sends put_file message with base64 content)
    op_msg = %{
      op: :put_file, path: path, client_op_id: client_op_id,
      content: base64_content, filename: filename, content_type: content_type
    }

    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, op_msg)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:enum, pattern}, _from, state) do
    results = state.cache.read_all(state.cache_target, state.store, pattern)
    {:reply, results, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    entry_count =
      if function_exported?(state.cache, :count, 2) do
        state.cache.count(state.cache_target, state.store)
      else
        nil
      end

    status = %{
      connection: state.status,
      last_store_seq: state.last_store_seq,
      pending_ops: map_size(state.pending_ops),
      entry_count: entry_count,
      store: state.store
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:cache_info, _from, state) do
    {:reply, {state.cache, state.cache_target}, state}
  end

  @impl true
  def handle_call({:on, pattern, callback, opts}, _from, state) do
    ref = Dust.CallbackRegistry.register(state.callbacks, state.store, pattern, callback, opts)
    {:reply, ref, state}
  end

  @impl true
  def handle_call({:seed_entry, path, value, type}, _from, state) do
    :ok = state.cache.write(state.cache_target, state.store, path, value, type, 0)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:set_store_seq, seq}, state) do
    {:noreply, %{state | last_store_seq: seq}}
  end

  @impl true
  def handle_cast({:set_status, new_status}, state) do
    # When becoming connected, resend all pending ops
    if new_status == :connected and map_size(state.pending_ops) > 0 do
      Enum.each(state.pending_ops, fn {_client_op_id, op_attrs} ->
        send_to_connection(state.store, op_attrs)
      end)
    end

    {:noreply, %{state | status: new_status}}
  end

  @impl true
  def handle_cast({:snapshot, snapshot}, state) do
    snapshot_seq = snapshot["snapshot_seq"]
    entries = snapshot["entries"]

    # Bulk replace cache with snapshot data
    Enum.each(entries, fn {path, %{"value" => value, "type" => type}} ->
      state.cache.write(state.cache_target, state.store, path, value, type, snapshot_seq)
    end)

    {:noreply, %{state | last_store_seq: snapshot_seq}}
  end

  @impl true
  def handle_cast({:catch_up_complete, through_seq}, state) do
    {:noreply, %{state | catch_up_seq: through_seq}}
  end

  @impl true
  def handle_cast({:write_rejected, client_op_id, reason}, state) do
    case Map.pop(state.pending_ops, client_op_id) do
      {nil, _pending} ->
        # Already reconciled or unknown op
        {:noreply, state}

      {op_attrs, pending} ->
        path = op_attrs.path

        # Roll back to previous value (or delete if there was none)
        case Map.get(op_attrs, :prev) do
          {:ok, prev_value} ->
            type = detect_type(prev_value)
            state.cache.write(state.cache_target, state.store, path, prev_value, type, 0)

          _ ->
            state.cache.delete(state.cache_target, state.store, path)
        end

        # Fire rejection callback so the app knows
        dispatch_callbacks(state, path, %{
          store: state.store,
          path: path,
          op: op_attrs.op,
          value: nil,
          committed: false,
          source: :server,
          client_op_id: client_op_id,
          error: %{code: :rejected, message: to_string(reason)}
        })

        {:noreply, %{state | pending_ops: pending}}
    end
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
        state.cache.write(state.cache_target, state.store, path, value, detect_type(value), store_seq)
      :delete ->
        state.cache.delete(state.cache_target, state.store, path)
      :merge when is_map(value) ->
        Enum.each(value, fn {key, v} ->
          child_path = "#{path}.#{key}"
          state.cache.write(state.cache_target, state.store, child_path, v, detect_type(v), store_seq)
        end)
      :increment ->
        # Server sends the materialized value (not the delta) for cache reconciliation
        state.cache.write(state.cache_target, state.store, path, value, "counter", store_seq)
      :add ->
        state.cache.write(state.cache_target, state.store, path, value, "set", store_seq)
      :remove ->
        state.cache.write(state.cache_target, state.store, path, value, "set", store_seq)
      :put_file ->
        state.cache.write(state.cache_target, state.store, path, value, "file", store_seq)
    end

    # Reconcile pending ops
    was_pending = Map.has_key?(state.pending_ops, client_op_id)
    pending = Map.delete(state.pending_ops, client_op_id)

    # Append to activity buffer for dashboard
    if state.activity_buffer do
      Dust.ActivityBuffer.append(state.activity_buffer, state.store, %{
        path: path,
        op: op,
        source: (if was_pending, do: :local, else: :server),
        seq: store_seq
      })
    end

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
    subscriptions = Dust.CallbackRegistry.match(state.callbacks, state.store, path)

    Enum.each(subscriptions, fn {worker_pid, ref, max_queue_size, on_resync} ->
      queue_len = Dust.CallbackWorker.queue_len(worker_pid)

      if queue_len >= max_queue_size do
        # Subscription has fallen behind — drop it and notify
        Dust.CallbackRegistry.unregister(state.callbacks, ref)

        if is_function(on_resync, 1) do
          on_resync.(%{error: :resync_required, ref: ref})
        end
      else
        Dust.CallbackWorker.dispatch(worker_pid, event)
      end
    end)
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

  defp detect_type(%Decimal{}), do: "decimal"
  defp detect_type(%DateTime{}), do: "datetime"
  defp detect_type(value) when is_boolean(value), do: "boolean"
  defp detect_type(value) when is_map(value), do: "map"
  defp detect_type(value) when is_binary(value), do: "string"
  defp detect_type(value) when is_integer(value), do: "integer"
  defp detect_type(value) when is_float(value), do: "float"
  defp detect_type(nil), do: "null"
  defp detect_type(_), do: "string"
end
