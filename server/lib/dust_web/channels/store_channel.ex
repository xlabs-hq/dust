defmodule DustWeb.StoreChannel do
  use Phoenix.Channel
  require Logger

  alias Dust.{Stores, Sync, Files}
  alias Dust.Sync.{Rollback, ValueCodec}

  @valid_ops %{
    "set" => :set,
    "delete" => :delete,
    "merge" => :merge,
    "increment" => :increment,
    "add" => :add,
    "remove" => :remove,
    "put_file" => :put_file
  }

  @impl true
  def join("store:" <> store_ref, %{"last_store_seq" => last_seq}, socket) do
    store_token = socket.assigns.store_token

    # Resolve store by full name (contains "/") or by UUID
    with {:ok, store} <- resolve_store(store_ref),
         true <- store_token.store_id == store.id and Stores.StoreToken.can_read?(store_token) do
      send(self(), {:catch_up, last_seq})

      current_seq = Sync.current_seq(store.id)

      socket =
        socket
        |> assign(:store_id, store.id)
        |> assign(:last_acked_seq, last_seq)

      Logger.metadata(store_id: store.id, device_id: socket.assigns.device_id)

      :telemetry.execute([:dust, :connection, :join], %{}, %{
        store_id: store.id,
        device_id: socket.assigns.device_id
      })

      {:ok,
       %{
         store_seq: current_seq,
         capver: DustProtocol.current_capver(),
         capver_min: DustProtocol.min_capver()
       }, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("write", params, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      case Dust.RateLimiter.check(store_token.id, :write) do
        {:error, :rate_limited, info} ->
          {:reply, {:error, %{reason: "rate_limited", retry_after_ms: info.retry_after_ms}},
           socket}

        :ok ->
          handle_write_op(params, socket)
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_in(
        "put_file",
        %{
          "path" => path,
          "content" => base64_content,
          "client_op_id" => client_op_id
        } = params,
        socket
      ) do
    store_token = socket.assigns.store_token

    with true <- Stores.StoreToken.can_write?(store_token),
         :ok <- Dust.RateLimiter.check(store_token.id, :write) do
      org = store_token.store.organization

      with {:ok, _} <- validate_path(path),
           {:ok, content} <- Base.decode64(base64_content),
           :ok <-
             Dust.Billing.Limits.check_file_storage(
               socket.assigns.store_id,
               byte_size(content),
               org
             ) do
        filename = params["filename"]
        content_type = params["content_type"] || "application/octet-stream"

        {:ok, ref} = Files.upload(content, filename: filename, content_type: content_type)

        op_attrs = %{
          op: :put_file,
          path: path,
          value: ref,
          device_id: socket.assigns.device_id,
          client_op_id: client_op_id
        }

        case Sync.write(socket.assigns.store_id, op_attrs) do
          {:ok, db_op} ->
            broadcast!(socket, "event", format_event(db_op))
            {:reply, {:ok, %{store_seq: db_op.store_seq, hash: ref["hash"]}}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end
      else
        :error ->
          {:reply, {:error, %{reason: "invalid_base64"}}, socket}

        {:error, :limit_exceeded, info} ->
          {:reply, {:error, %{reason: "limit_exceeded"} |> Map.merge(info)}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      false ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}

      {:error, :rate_limited, info} ->
        {:reply, {:error, %{reason: "rate_limited", retry_after_ms: info.retry_after_ms}}, socket}
    end
  end

  @impl true
  def handle_in("rollback", %{"path" => path, "to_seq" => to_seq}, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      case Rollback.rollback_path(socket.assigns.store_id, path, to_seq) do
        {:ok, :noop} ->
          {:reply, {:ok, %{store_seq: Sync.current_seq(socket.assigns.store_id), noop: true}},
           socket}

        {:ok, op} ->
          broadcast!(socket, "event", format_event(op))
          {:reply, {:ok, %{store_seq: op.store_seq}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  def handle_in("rollback", %{"to_seq" => to_seq}, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      case Rollback.rollback_store(socket.assigns.store_id, to_seq) do
        {:ok, count} ->
          {:reply, {:ok, %{ops_written: count}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  def handle_in("ack_seq", %{"seq" => seq}, socket) do
    socket = assign(socket, :last_acked_seq, seq)
    {:reply, :ok, socket}
  end

  def handle_in("status", _params, socket) do
    store_id = socket.assigns.store_id
    status = build_status(store_id)
    {:reply, {:ok, status}, socket}
  end

  defp handle_write_op(params, socket) do
    case Map.get(@valid_ops, params["op"]) do
      nil ->
        {:reply, {:error, %{reason: "invalid op"}}, socket}

      op ->
        org = socket.assigns.store_token.store.organization

        with {:ok, _} <- validate_path(params["path"]),
             :ok <- validate_merge_value(op, params["value"]),
             :ok <- check_billing_limits(op, params, socket.assigns.store_id, org) do
          op_attrs = %{
            op: op,
            path: params["path"],
            value: params["value"],
            device_id: socket.assigns.device_id,
            client_op_id: params["client_op_id"]
          }

          case Sync.write(socket.assigns.store_id, op_attrs) do
            {:ok, db_op} ->
              broadcast!(socket, "event", format_event(db_op))
              {:reply, {:ok, %{store_seq: db_op.store_seq}}, socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: inspect(reason)}}, socket}
          end
        else
          {:error, :limit_exceeded, info} ->
            {:reply, {:error, %{reason: "limit_exceeded"} |> Map.merge(info)}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end
    end
  end

  @impl true
  def handle_info({:catch_up, last_seq}, socket) do
    store_id = socket.assigns.store_id

    # Check if client is behind a snapshot
    case Sync.get_latest_snapshot(store_id) do
      %{snapshot_seq: snap_seq} = snapshot when snap_seq > last_seq ->
        # Client is behind the snapshot — send full snapshot first
        push(socket, "snapshot", %{
          snapshot_seq: snap_seq,
          entries: snapshot.snapshot_data
        })

        # Then send any ops after the snapshot
        send(self(), {:catch_up_after_snapshot, snap_seq})
        {:noreply, socket}

      _ ->
        do_catch_up(store_id, last_seq, socket)
    end
  end

  @impl true
  def handle_info({:catch_up_after_snapshot, last_seq}, socket) do
    do_catch_up(socket.assigns.store_id, last_seq, socket)
  end

  defp do_catch_up(store_id, last_seq, socket) do
    ops = Sync.get_ops_since(store_id, last_seq)

    {last_sent_seq, _running_state} =
      if ops == [] do
        {last_seq, %{}}
      else
        # Seed running state for paths that have increment/add/remove ops
        running_state = seed_running_state(store_id, last_seq, ops)

        Enum.reduce(ops, {last_seq, running_state}, fn op, {_, state} ->
          {value, state} = materialize_catch_up_value(op, state)

          event = %{
            store_seq: op.store_seq,
            op: op.op,
            path: op.path,
            value: value,
            device_id: op.device_id,
            client_op_id: op.client_op_id
          }

          push(socket, "event", event)
          {op.store_seq, state}
        end)
      end

    # If we got a full batch, there may be more ops to send
    if length(ops) >= 1000 do
      send(self(), {:catch_up, last_sent_seq})
    else
      # Catch-up complete — tell the client
      push(socket, "catch_up_complete", %{through_seq: last_sent_seq})
    end

    {:noreply, socket}
  end

  # For live writes, use the materialized_value virtual field (set by Writer)
  defp format_event(op) do
    value =
      case Map.get(op, :materialized_value) do
        nil -> ValueCodec.unwrap(op.value)
        mat -> mat
      end

    %{
      store_seq: op.store_seq,
      op: op.op,
      path: op.path,
      value: value,
      device_id: op.device_id,
      client_op_id: op.client_op_id
    }
  end

  # Seed running state for paths that need incremental materialization.
  # For the first occurrence of each path with increment/add/remove in the batch,
  # we need the value at last_seq so we can replay deltas forward.
  defp seed_running_state(store_id, last_seq, ops) do
    needs_seed =
      ops
      |> Enum.filter(fn op -> op.op in [:increment, :add, :remove] end)
      |> Enum.map(& &1.path)
      |> Enum.uniq()

    if needs_seed == [] do
      %{}
    else
      state = Rollback.compute_historical_state(store_id, last_seq)

      (state || %{})
      |> Map.take(needs_seed)
      |> Enum.into(%{}, fn {path, wrapped} -> {path, ValueCodec.unwrap(wrapped)} end)
    end
  end

  defp materialize_catch_up_value(%{op: :increment} = op, state) do
    current = Map.get(state, op.path, 0)
    delta = ValueCodec.unwrap(op.value) || 0
    new_value = current + delta
    {new_value, Map.put(state, op.path, new_value)}
  end

  defp materialize_catch_up_value(%{op: :add} = op, state) do
    current_set = Map.get(state, op.path, [])
    member = ValueCodec.unwrap(op.value)
    new_set = Enum.uniq([member | current_set])
    {new_set, Map.put(state, op.path, new_set)}
  end

  defp materialize_catch_up_value(%{op: :remove} = op, state) do
    current_set = Map.get(state, op.path, [])
    member = ValueCodec.unwrap(op.value)
    new_set = List.delete(current_set, member)
    {new_set, Map.put(state, op.path, new_set)}
  end

  defp materialize_catch_up_value(op, state) do
    value = ValueCodec.unwrap(op.value)
    {value, state}
  end

  defp build_status(store_id) do
    import Ecto.Query

    current_seq = Sync.current_seq(store_id)
    entry_count = Sync.entry_count(store_id)

    store_meta =
      Dust.Repo.one(
        from(s in Dust.Stores.Store,
          where: s.id == ^store_id,
          select: %{op_count: s.op_count, file_storage_bytes: s.file_storage_bytes}
        )
      )

    snapshot = Sync.get_latest_snapshot(store_id)

    recent_ops = Sync.get_ops_page(store_id, limit: 5, offset: 0)

    db_size =
      case Dust.Sync.StoreDB.path_for_id(store_id) do
        {:ok, path} ->
          case File.stat(path) do
            {:ok, %{size: size}} -> size
            _ -> 0
          end

        _ ->
          0
      end

    %{
      current_seq: current_seq,
      entry_count: entry_count,
      op_count: (store_meta && store_meta.op_count) || 0,
      file_storage_bytes: (store_meta && store_meta.file_storage_bytes) || 0,
      db_size_bytes: db_size,
      latest_snapshot_seq: snapshot && snapshot.snapshot_seq,
      latest_snapshot_at: snapshot && Map.get(snapshot, :inserted_at),
      recent_ops:
        Enum.map(recent_ops, fn op ->
          %{
            store_seq: op.store_seq,
            op: op.op,
            path: op.path,
            inserted_at: op.inserted_at
          }
        end)
    }
  end

  # If the store_ref contains "/", it's a full name like "org/store".
  # Otherwise, treat it as a UUID.
  defp resolve_store(store_ref) do
    if String.contains?(store_ref, "/") do
      case Stores.get_store_by_full_name(store_ref) do
        nil -> {:error, :not_found}
        store -> {:ok, store}
      end
    else
      case Dust.Repo.get(Dust.Stores.Store, store_ref) do
        nil -> {:error, :not_found}
        store -> {:ok, store}
      end
    end
  end

  defp validate_path(nil), do: {:error, :missing_path}
  defp validate_path(path) when is_binary(path), do: DustProtocol.Path.parse(path)
  defp validate_path(_), do: {:error, :invalid_path}

  defp validate_merge_value(:merge, value) when is_map(value), do: :ok
  defp validate_merge_value(:merge, _), do: {:error, :merge_requires_map_value}
  defp validate_merge_value(:increment, value) when is_number(value), do: :ok
  defp validate_merge_value(:increment, _), do: {:error, :increment_requires_number_value}
  defp validate_merge_value(:add, nil), do: {:error, :add_requires_value}
  defp validate_merge_value(:add, _), do: :ok
  defp validate_merge_value(:remove, nil), do: {:error, :remove_requires_value}
  defp validate_merge_value(:remove, _), do: :ok
  defp validate_merge_value(_, _), do: :ok

  # Billing checks — only for ops that create new keys
  defp check_billing_limits(:set, %{"path" => path, "value" => value}, store_id, org) do
    # Count how many new leaf entries this set would create
    new_keys =
      if is_map(value) and not ValueCodec.typed_value?(value) do
        leaves = ValueCodec.flatten_map(path, value)

        Enum.count(leaves, fn {leaf_path, _} ->
          Sync.get_entry(store_id, leaf_path) == nil
        end)
      else
        if Sync.get_entry(store_id, path), do: 0, else: 1
      end

    if new_keys > 0 do
      Dust.Billing.Limits.check_key_count(store_id, new_keys, org)
    else
      :ok
    end
  end

  defp check_billing_limits(:merge, %{"path" => path, "value" => value}, store_id, org)
       when is_map(value) do
    # Count net-new paths from merge using full path prefix
    new_keys =
      Enum.count(value, fn {key, _v} ->
        Sync.get_entry(store_id, "#{path}.#{key}") == nil
      end)

    if new_keys > 0 do
      Dust.Billing.Limits.check_key_count(store_id, new_keys, org)
    else
      :ok
    end
  end

  defp check_billing_limits(_, _, _, _), do: :ok

  @impl true
  def terminate(_reason, socket) do
    if store_id = socket.assigns[:store_id] do
      :telemetry.execute([:dust, :connection, :leave], %{}, %{
        store_id: store_id,
        device_id: socket.assigns[:device_id]
      })
    end

    :ok
  end
end
