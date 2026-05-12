defmodule Dust.SyncEngine do
  use GenServer

  defstruct [
    :store,
    :cache,
    :cache_target,
    :callbacks,
    :pending_ops,
    :status,
    :last_store_seq,
    :catch_up_seq,
    :activity_buffer,
    # HTTP base URL (derived from the WS url) and bearer token, kept
    # here so FileRefs unwrapped from the cache carry the auth context
    # they need to fetch blob content via /api/files/:hash.
    :http_url,
    :token
  ]

  def start_link(opts) do
    store = Keyword.fetch!(opts, :store)
    GenServer.start_link(__MODULE__, opts, name: via(store))
  end

  def via(store), do: {:via, Registry, {Dust.SyncEngineRegistry, store}}

  # Normalize a user-supplied path to canonical slash-rendered form.
  # Accepts segment lists, canonical slash strings, and legacy dotted
  # strings; returns the slash-rendered form used everywhere downstream
  # (cache keys, wire protocol). Raises ArgumentError on invalid input —
  # paths that can't be normalised are programmer errors, not runtime
  # conditions.
  defp norm!(path) when is_list(path) do
    case Dust.Protocol.Path.render(path) do
      {:ok, p} -> p
      {:error, reason} -> raise ArgumentError, "invalid path #{inspect(path)}: #{reason}"
    end
  end

  defp norm!(path) when is_binary(path) do
    cond do
      String.contains?(path, "/") ->
        case Dust.Protocol.Path.normalize_rendered(path) do
          {:ok, p} -> p
          {:error, reason} -> raise ArgumentError, "invalid path #{inspect(path)}: #{reason}"
        end

      true ->
        case Dust.Protocol.Path.LegacyDot.parse(path) do
          {:ok, segs} ->
            case Dust.Protocol.Path.render(segs) do
              {:ok, p} -> p
              {:error, reason} -> raise ArgumentError, "invalid path #{inspect(path)}: #{reason}"
            end

          {:error, reason} ->
            raise ArgumentError, "invalid path #{inspect(path)}: #{reason}"
        end
    end
  end

  # Wildcards in patterns survive both normalisation routes.
  defp norm_pattern!("**"), do: "**"
  defp norm_pattern!(pattern) when is_list(pattern), do: norm!(pattern)

  defp norm_pattern!(pattern) when is_binary(pattern) do
    cond do
      String.contains?(pattern, "/") ->
        case Dust.Protocol.Glob.compile(pattern) do
          {:ok, _} -> pattern
          {:error, reason} -> raise ArgumentError, "invalid pattern #{inspect(pattern)}: #{reason}"
        end

      true ->
        case Dust.Protocol.Path.LegacyDot.normalize_pattern(pattern) do
          {:ok, dotted} ->
            dotted |> String.split(".") |> Enum.join("/")

          {:error, reason} ->
            raise ArgumentError, "invalid pattern #{inspect(pattern)}: #{reason}"
        end
    end
  end

  def get(store, path) do
    GenServer.call(via(store), {:get, norm!(path)})
  end

  def get_many(store, paths) when is_list(paths) do
    GenServer.call(via(store), {:get_many, Enum.map(paths, &norm!/1)})
  end

  def put(store, path, value) do
    GenServer.call(via(store), {:put, norm!(path), value})
  end

  def put(store, path, value, opts) when is_list(opts) do
    GenServer.call(via(store), {:put, norm!(path), value, opts})
  end

  def delete(store, path) do
    GenServer.call(via(store), {:delete, norm!(path)})
  end

  def delete(store, path, opts) when is_list(opts) do
    GenServer.call(via(store), {:delete, norm!(path), opts})
  end

  def merge(store, path, map) do
    GenServer.call(via(store), {:merge, norm!(path), map})
  end

  def merge(store, path, map, opts) when is_list(opts) do
    GenServer.call(via(store), {:merge, norm!(path), map, opts})
  end

  def increment(store, path, delta \\ 1) do
    GenServer.call(via(store), {:increment, norm!(path), delta})
  end

  def increment(store, path, delta, opts) when is_list(opts) do
    GenServer.call(via(store), {:increment, norm!(path), delta, opts})
  end

  def add(store, path, member) do
    GenServer.call(via(store), {:add, norm!(path), member})
  end

  def add(store, path, member, opts) when is_list(opts) do
    GenServer.call(via(store), {:add, norm!(path), member, opts})
  end

  def remove(store, path, member) do
    GenServer.call(via(store), {:remove, norm!(path), member})
  end

  def remove(store, path, member, opts) when is_list(opts) do
    GenServer.call(via(store), {:remove, norm!(path), member, opts})
  end

  def put_file(store, path, source_path, opts \\ []) do
    GenServer.call(via(store), {:put_file, norm!(path), source_path, opts})
  end

  def enum(store, pattern) do
    GenServer.call(via(store), {:enum, norm_pattern!(pattern)})
  end

  def enum(store, pattern, opts) when is_list(opts) do
    GenServer.call(via(store), {:enum_paged, norm_pattern!(pattern), opts})
  end

  def range(store, from, to, opts \\ []) when is_binary(from) and is_binary(to) do
    GenServer.call(via(store), {:range, norm!(from), norm!(to), opts})
  end

  def entry(store, path) do
    GenServer.call(via(store), {:entry, norm!(path)})
  end

  def status(store) do
    GenServer.call(via(store), :status)
  end

  def on(store, pattern, callback, opts \\ []) do
    GenServer.call(via(store), {:on, norm_pattern!(pattern), callback, opts})
  end

  @doc """
  Remove a subscription previously registered with `on/4`. Returns `:ok`
  whether or not a subscription with that ref existed (idempotent). After
  this call returns, the subscription's callback will not fire again.
  """
  def off(store, ref) when is_reference(ref) do
    GenServer.call(via(store), {:off, ref})
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

  def handle_write_accepted(store, client_op_id, store_seq) do
    GenServer.cast(via(store), {:write_accepted, client_op_id, store_seq})
  end

  def set_catch_up_complete(store, through_seq) do
    GenServer.cast(via(store), {:catch_up_complete, through_seq})
  end

  def handle_snapshot(store, snapshot) do
    GenServer.cast(via(store), {:snapshot, snapshot})
  end

  @doc "Write directly to cache without the write pipeline. For test seeding only."
  def seed_entry(store, path, value, type) do
    GenServer.call(via(store), {:seed_entry, norm!(path), value, type})
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
      activity_buffer: activity_buffer,
      http_url: derive_http_url(Keyword.get(opts, :url)),
      token: Keyword.get(opts, :token)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get, path}, _from, state) do
    result =
      case state.cache.read(state.cache_target, state.store, path) do
        {:ok, value} ->
          {:ok, unwrap_value(value, state)}

        :miss ->
          case assemble_subtree_value(state, path) do
            nil -> :miss
            value -> {:ok, value}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_many, paths}, _from, state) do
    raw = state.cache.read_many(state.cache_target, state.store, paths)

    result =
      Enum.reduce(raw, %{}, fn {path, {value, _type, _seq}}, acc ->
        Map.put(acc, path, unwrap_value(value, state))
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:put, path, value}, _from, state) do
    {op_msg, state} = do_put(path, value, [], nil, state)
    send_to_connection(state.store, op_msg)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:put, path, value, opts}, from, state) do
    {op_msg, state} = do_put(path, value, opts, from, state)
    send_to_connection(state.store, op_msg)
    {:noreply, state}
  end

  @impl true
  def handle_call({:delete, path}, _from, state) do
    state = do_delete(path, nil, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, path, _opts}, from, state) do
    state = do_delete(path, from, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:merge, path, map}, _from, state) do
    state = do_merge(path, map, nil, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:merge, path, map, _opts}, from, state) do
    state = do_merge(path, map, from, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:increment, path, delta}, _from, state) do
    state = do_increment(path, delta, nil, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:increment, path, delta, _opts}, from, state) do
    state = do_increment(path, delta, from, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:add, path, member}, _from, state) do
    state = do_set_op(:add, path, member, nil, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add, path, member, _opts}, from, state) do
    state = do_set_op(:add, path, member, from, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:remove, path, member}, _from, state) do
    state = do_set_op(:remove, path, member, nil, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove, path, member, _opts}, from, state) do
    state = do_set_op(:remove, path, member, from, state)
    {:noreply, state}
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
  def handle_call({:enum_paged, pattern, opts}, _from, state) do
    with :ok <- validate_enum_opts(pattern, opts) do
      limit = opts |> Keyword.get(:limit, 50) |> min(1000)
      order = Keyword.get(opts, :order, :asc)
      select = Keyword.get(opts, :select, :entries)
      cursor = Keyword.get(opts, :after)

      browse_opts = [
        pattern: pattern,
        limit: limit,
        order: order,
        select: select,
        cursor: cursor
      ]

      {items, next_cursor} = state.cache.browse(state.cache_target, state.store, browse_opts)
      page = Dust.Page.new(items: wrap_items(items, select), next_cursor: next_cursor)
      {:reply, page, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:range, from, to, opts}, _from, state) do
    case Keyword.get(opts, :select, :entries) do
      :prefixes ->
        {:reply, {:error, :unsupported_select}, state}

      select when select in [:entries, :keys] ->
        limit = opts |> Keyword.get(:limit, 50) |> min(1000)
        order = Keyword.get(opts, :order, :asc)
        cursor = Keyword.get(opts, :after)

        browse_opts = [
          from: from,
          to: to,
          limit: limit,
          order: order,
          select: select,
          cursor: cursor
        ]

        {items, next_cursor} = state.cache.browse(state.cache_target, state.store, browse_opts)
        page = Dust.Page.new(items: wrap_items(items, select), next_cursor: next_cursor)
        {:reply, page, state}
    end
  end

  @impl true
  def handle_call({:entry, path}, _from, state) do
    reply =
      case state.cache.read_entry(state.cache_target, state.store, path) do
        {:ok, {value, type, seq}} ->
          {:ok, Dust.Entry.new(path: path, value: value, type: type, revision: seq)}

        :miss ->
          case assemble_subtree_entry(state, path) do
            nil -> {:error, :not_found}
            entry -> {:ok, entry}
          end
      end

    {:reply, reply, state}
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
  def handle_call({:off, ref}, _from, state) do
    Dust.CallbackRegistry.unregister(state.callbacks, ref)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:on, pattern, callback, opts}, _from, state) do
    ref = Dust.CallbackRegistry.register(state.callbacks, state.store, pattern, callback, opts)

    # Bootstrap current matching entries if requested. Runs INSIDE handle_call
    # so no live events can fire between snapshot and return — the single-threaded
    # GenServer guarantees bootstrap items hit the worker mailbox before any
    # subsequent live event dispatched to the same worker.
    if Keyword.get(opts, :include_current, false) do
      emit_bootstrap_events(state, pattern, ref, opts)
    end

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

        # If a put/4 caller is awaiting a reply, surface the error.
        case Map.get(op_attrs, :from) do
          nil -> :ok
          from -> GenServer.reply(from, {:error, reason_to_atom(reason)})
        end

        {:noreply, %{state | pending_ops: pending}}
    end
  end

  @impl true
  def handle_cast({:write_accepted, client_op_id, store_seq}, state) do
    case Map.get(state.pending_ops, client_op_id) do
      nil ->
        {:noreply, state}

      op_attrs ->
        # Reply to any put/4 caller waiting for the server ack.
        case Map.get(op_attrs, :from) do
          nil ->
            :ok

          from ->
            GenServer.reply(from, {:ok, store_seq})
        end

        # Leave pending_ops intact — it's cleared by :server_event reconciliation
        # so rollback on later rejection (by reason like :rate_limited) still works.
        # But once we've replied successfully, drop the :from so subsequent events
        # don't double-reply.
        pending =
          Map.update(state.pending_ops, client_op_id, op_attrs, fn attrs ->
            Map.delete(attrs, :from)
          end)

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

    # Update cache with canonical state. Plain-map :set ops flatten to leaf
    # entries (matching server storage); :delete clears the path AND every
    # descendant so subtree deletes propagate to local subscribers.
    case op do
      :set ->
        apply_set_to_cache(state, path, value, detect_type(value), store_seq)

      :delete ->
        _ = state.cache.delete_subtree(state.cache_target, state.store, path)

      :merge when is_map(value) ->
        {:ok, prefix_segs} = Dust.Protocol.Path.parse_rendered(path)

        Enum.each(value, fn {key, v} ->
          {:ok, child_segs} = Dust.Protocol.Path.child(prefix_segs, to_string(key))
          {:ok, child_path} = Dust.Protocol.Path.render(child_segs)
          apply_set_to_cache(state, child_path, v, detect_type(v), store_seq)
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

    # Always dispatch the committed event with was_own carrying whether
    # this was our own write being echoed. Subscriptions filter by mode:
    # `:all` (the default) skips the echo of own writes (preserving the
    # historical single-fire semantics); `:committed` keeps it; `:optimistic`
    # ignores committed events entirely.
    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: op, value: value,
      store_seq: store_seq, committed: true, was_own: was_pending,
      source: :server, device_id: event["device_id"],
      client_op_id: client_op_id
    })

    state = %{state | pending_ops: pending, last_store_seq: store_seq}
    {:noreply, state}
  end

  defp dispatch_callbacks(state, path, event) do
    subscriptions = Dust.CallbackRegistry.match(state.callbacks, state.store, path)
    Enum.each(subscriptions, &dispatch_to_subscription(state, &1, event))
  end

  # Single canonical dispatch path: check backpressure, drop subscription +
  # fire on_resync on overflow, otherwise enqueue via CallbackWorker.dispatch.
  # Used by both live dispatch (dispatch_callbacks/3) and bootstrap
  # (emit_bootstrap_events/4) so the semantics are identical.
  defp dispatch_to_subscription(
         state,
         {worker_pid, ref, max_queue_size, on_resync, mode},
         event
       ) do
    if event_matches_mode?(mode, event) do
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
    end
  end

  # `:all` preserves historical behaviour: optimistic for own writes (one
  # fire, no store_seq) and committed for others' writes (one fire, with
  # store_seq). `:committed` always wants the post-server event with
  # store_seq, including for own writes. `:optimistic` ignores committed
  # events entirely. Bootstrap events (`type: :present`) flow to every mode.
  defp event_matches_mode?(_mode, %{type: :present}), do: true

  defp event_matches_mode?(:all, %{committed: true, was_own: true}), do: false
  defp event_matches_mode?(:all, _), do: true

  defp event_matches_mode?(:committed, %{committed: true}), do: true
  defp event_matches_mode?(:committed, _), do: false

  defp event_matches_mode?(:optimistic, %{committed: false}), do: true
  defp event_matches_mode?(:optimistic, _), do: false

  defp emit_bootstrap_events(state, pattern, ref, opts) do
    limit = opts |> Keyword.get(:limit, 50) |> min(1000)
    order = Keyword.get(opts, :order, :asc)

    browse_opts = [
      pattern: pattern,
      limit: limit,
      order: order,
      select: :entries
    ]

    {items, _next_cursor} = state.cache.browse(state.cache_target, state.store, browse_opts)

    case Dust.CallbackRegistry.lookup(state.callbacks, ref) do
      nil ->
        :ok

      {worker_pid, max_queue_size, on_resync, mode} ->
        subscription = {worker_pid, ref, max_queue_size, on_resync, mode}

        Enum.reduce_while(items, subscription, fn {path, value, type, seq}, sub ->
          event = %{
            type: :present,
            path: path,
            value: value,
            entry_type: type,
            seq: seq
          }

          dispatch_to_subscription(state, sub, event)

          # If backpressure dropped the subscription during bootstrap, stop.
          if Dust.CallbackRegistry.lookup(state.callbacks, ref) == nil do
            {:halt, sub}
          else
            {:cont, sub}
          end
        end)

        :ok
    end
  end

  defp do_put(path, value, opts, from, state) do
    client_op_id = generate_op_id()
    type = detect_type(value)

    # Save previous value for rollback on rejection
    prev = state.cache.read(state.cache_target, state.store, path)

    # Optimistic local write — canonicalized to match server shape: plain-map
    # values get flattened to leaf entries, descendants cleared, no root leaf.
    :ok = apply_set_to_cache(state, path, value, type, 0)

    # Fire local callbacks
    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :set, value: value,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg =
      %{op: :set, path: path, value: value, client_op_id: client_op_id, prev: prev}
      |> maybe_put_if_match(opts)
      |> maybe_put_from(from)

    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    {op_msg, %{state | pending_ops: pending}}
  end

  defp maybe_put_if_match(op_msg, opts) do
    case Keyword.fetch(opts, :if_match) do
      {:ok, value} -> Map.put(op_msg, :if_match, value)
      :error -> op_msg
    end
  end

  defp maybe_put_from(op_msg, nil), do: op_msg
  defp maybe_put_from(op_msg, from), do: Map.put(op_msg, :from, from)

  defp do_delete(path, from, state) do
    client_op_id = generate_op_id()

    # Optimistic delete clears the leaf AND every descendant, matching the
    # server's DELETE op semantics so the cache stays consistent.
    _ = state.cache.delete_subtree(state.cache_target, state.store, path)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :delete, value: nil,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg =
      %{op: :delete, path: path, client_op_id: client_op_id}
      |> maybe_put_from(from)

    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    send_to_connection(state.store, op_msg)
    %{state | pending_ops: pending}
  end

  defp do_merge(path, map, from, state) do
    client_op_id = generate_op_id()
    {:ok, prefix_segs} = Dust.Protocol.Path.parse_rendered(path)

    Enum.each(map, fn {key, value} ->
      {:ok, child_segs} = Dust.Protocol.Path.child(prefix_segs, to_string(key))
      {:ok, child_path} = Dust.Protocol.Path.render(child_segs)
      state.cache.write(state.cache_target, state.store, child_path, value, detect_type(value), 0)
    end)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :merge, value: map,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg =
      %{op: :merge, path: path, value: map, client_op_id: client_op_id}
      |> maybe_put_from(from)

    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    send_to_connection(state.store, op_msg)
    %{state | pending_ops: pending}
  end

  defp do_increment(path, delta, from, state) do
    client_op_id = generate_op_id()

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

    op_msg =
      %{op: :increment, path: path, value: delta, client_op_id: client_op_id}
      |> maybe_put_from(from)

    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    send_to_connection(state.store, op_msg)
    %{state | pending_ops: pending}
  end

  defp do_set_op(op, path, member, from, state) when op in [:add, :remove] do
    client_op_id = generate_op_id()

    current_set =
      case state.cache.read(state.cache_target, state.store, path) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    new_set =
      case op do
        :add -> Enum.uniq([member | current_set])
        :remove -> List.delete(current_set, member)
      end

    :ok = state.cache.write(state.cache_target, state.store, path, new_set, "set", 0)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: op, value: member,
      committed: false, source: :local, client_op_id: client_op_id
    })

    op_msg =
      %{op: op, path: path, value: member, client_op_id: client_op_id}
      |> maybe_put_from(from)

    pending = Map.put(state.pending_ops, client_op_id, op_msg)
    send_to_connection(state.store, op_msg)
    %{state | pending_ops: pending}
  end

  defp reason_to_atom(reason) when is_atom(reason), do: reason
  defp reason_to_atom("conflict"), do: :conflict
  defp reason_to_atom("rate_limited"), do: :rate_limited
  defp reason_to_atom("unauthorized"), do: :unauthorized
  defp reason_to_atom("invalid_op"), do: :invalid_op
  defp reason_to_atom("capver_mismatch"), do: :capver_mismatch
  defp reason_to_atom("if_match_unsupported_op"), do: :if_match_unsupported_op
  defp reason_to_atom("if_match_multi_leaf"), do: :if_match_multi_leaf
  # Unknown string reasons are returned as-is so callers see the server's
  # raw reason without risking unsafe atom creation.
  defp reason_to_atom(reason) when is_binary(reason), do: reason
  defp reason_to_atom(_), do: :unknown

  defp send_to_connection(store, op_attrs) do
    case GenServer.whereis(Dust.Connection) do
      nil -> :ok
      pid -> send(pid, {:send_write, store, op_attrs})
    end
  end

  defp generate_op_id do
    "op_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp validate_enum_opts(pattern, opts) do
    case Keyword.get(opts, :select, :entries) do
      :prefixes ->
        if valid_prefix_pattern?(pattern), do: :ok, else: {:error, :invalid_pattern_for_prefixes}

      _ ->
        :ok
    end
  end

  defp valid_prefix_pattern?("**"), do: true
  defp valid_prefix_pattern?(pattern), do: String.ends_with?(pattern, "/**")

  defp wrap_items(items, :entries) do
    Enum.map(items, fn {path, value, type, seq} ->
      Dust.Entry.new(path: path, value: value, type: type, revision: seq)
    end)
  end

  defp wrap_items(items, :keys), do: items
  defp wrap_items(items, :prefixes), do: items

  defp unwrap_value(%{"_type" => "file"} = map, state) do
    Dust.FileRef.from_map(map, server_url: state.http_url, token: state.token)
  end

  defp unwrap_value(other, _state), do: other

  defp derive_http_url(nil), do: nil

  defp derive_http_url(ws_url) when is_binary(ws_url) do
    case URI.parse(ws_url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        http_scheme = if scheme in ["wss", "https"], do: "https", else: "http"
        port_part = if port, do: ":#{port}", else: ""
        "#{http_scheme}://#{host}#{port_part}"

      _ ->
        nil
    end
  end

  # --- Subtree assembly + canonicalization ---

  # `Dust.get/2` and `Dust.entry/2` fall back to subtree assembly when the
  # exact path has no leaf — matching the server's `assemble_subtree`
  # behaviour. After a map-mode write, leaves live at `<path>.<field>` and
  # nothing lives at `<path>` itself.
  defp assemble_subtree_value(state, path) do
    case state.cache.read_subtree(state.cache_target, state.store, path) do
      [] ->
        nil

      rows ->
        {:ok, prefix_segments} = Dust.Protocol.Path.parse_rendered(path)
        prefix_len = length(prefix_segments)

        Enum.reduce(rows, %{}, fn {p, value, _type, _seq}, acc ->
          case Dust.Protocol.Path.parse_rendered(p) do
            {:ok, entry_segments} when length(entry_segments) > prefix_len ->
              keys = Enum.drop(entry_segments, prefix_len)
              put_nested(acc, keys, unwrap_value(value, state))

            _ ->
              # Exact-path row or unparsable — skip.
              acc
          end
        end)
    end
  end

  defp assemble_subtree_entry(state, path) do
    case state.cache.read_subtree(state.cache_target, state.store, path) do
      [] ->
        nil

      rows ->
        max_seq = rows |> Enum.map(fn {_, _, _, seq} -> seq end) |> Enum.max()
        value = assemble_subtree_value(state, path)
        Dust.Entry.new(path: path, value: value, type: "map", revision: max_seq)
    end
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, put_nested(child, rest, value))
  end

  # A typed-value map represents a single value (file ref, decimal,
  # datetime, etc.), not a record-shaped object. Two cases:
  #
  # 1. Any struct (Decimal, DateTime, Dust.FileRef, ...). Structs are
  #    explicitly typed and must not be flattened — `%Decimal{coef: 5}`
  #    is one value, not a record.
  # 2. Maps wearing the canonical `_typed` + `_type` wire shape (used for
  #    typed values that have already been serialized to the wire).
  #
  # Plain object maps (no struct, no _typed/_type) are records and must
  # flatten to leaves on write to match server canonical form.
  defp typed_map?(value) when is_struct(value), do: true

  # Mirrors Dust.Sync.ValueCodec.typed_value?/1 on the server. File refs
  # are recognized by `_type: "file"` alone; other typed wrappers carry
  # both `_typed` and `_type` keys.
  defp typed_map?(%{"_type" => "file"}), do: true
  defp typed_map?(%{_type: "file"}), do: true
  defp typed_map?(%{"_typed" => _, "_type" => _}), do: true
  defp typed_map?(%{_typed: _, _type: _}), do: true
  defp typed_map?(_), do: false

  # Apply a `:set` op to the cache canonically. Plain-map values get
  # flattened: descendants under `path` are cleared first, then each leaf is
  # written. Typed values and scalars write at the exact path. Mirrors the
  # server's `Dust.Sync.Writer.apply_to_entries({:set, ...})` shape so the
  # cache stays consistent regardless of whether the data arrived from a
  # local optimistic write or a server event echo.
  defp apply_set_to_cache(state, path, value, type, seq) do
    if is_map(value) and not typed_map?(value) do
      _ = state.cache.delete_subtree(state.cache_target, state.store, path)
      flatten_into_cache(state, path, value, seq)
    else
      :ok = state.cache.write(state.cache_target, state.store, path, value, type, seq)
    end
  end

  defp flatten_into_cache(state, base_path, map, seq) when is_map(map) do
    {:ok, base_segs} = Dust.Protocol.Path.parse_rendered(base_path)

    Enum.each(map, fn {key, value} ->
      {:ok, child_segs} = Dust.Protocol.Path.child(base_segs, to_string(key))
      {:ok, child_path} = Dust.Protocol.Path.render(child_segs)

      if is_map(value) and not typed_map?(value) do
        flatten_into_cache(state, child_path, value, seq)
      else
        leaf_type = detect_type(value)
        :ok = state.cache.write(state.cache_target, state.store, child_path, value, leaf_type, seq)
      end
    end)
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
