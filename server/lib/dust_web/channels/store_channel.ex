defmodule DustWeb.StoreChannel do
  use Phoenix.Channel

  alias Dust.AccessTokens
  alias Dust.{Stores, Sync, Files}
  alias Dust.Sync.{Rollback, ValueCodec}

  @valid_ops %{
    "set" => :set,
    "delete" => :delete,
    "merge" => :merge,
    "increment" => :increment,
    "add" => :add,
    "remove" => :remove,
    "put_file" => :put_file,
    "lease" => :lease,
    "renew" => :renew,
    "release" => :release
  }

  @impl true
  def join("store:" <> store_ref, %{"last_store_seq" => last_seq}, socket) do
    store_token = socket.assigns.store_token

    # Resolve store by full name (contains "/") or by UUID
    with {:ok, store} <- resolve_store(store_ref),
         :ok <- AccessTokens.authorize_store(store_token, store, "entries:read") do
      send(self(), {:catch_up, last_seq})

      current_seq = Sync.current_seq(store.id)

      socket =
        socket
        |> assign(:store_id, store.id)
        |> assign(:store, store)
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
         capver_min: DustProtocol.min_capver(),
         permissions: AccessTokens.capabilities(store_token, store).permissions,
         scopes: store_token.scopes,
         store_access: AccessTokens.capabilities(store_token).store_access
       }, socket}
    else
      {:error, reason} -> {:error, auth_error(reason)}
    end
  end

  @impl true
  def handle_in("write", params, socket) do
    store_token = socket.assigns.store_token

    with :ok <- authorize_current_store(socket, "entries:write"),
         :ok <- Dust.RateLimiter.check(store_token.id, :write) do
      handle_write_op(params, socket)
    else
      {:error, :rate_limited, info} ->
        {:reply, {:error, %{reason: "rate_limited", retry_after_ms: info.retry_after_ms}}, socket}

      {:error, reason} ->
        {:reply, {:error, auth_error(reason)}, socket}
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

    with :ok <- authorize_current_store(socket, "files:write"),
         :ok <- Dust.RateLimiter.check(store_token.id, :write) do
      org = store_token.organization

      with :ok <- verify_store_active(socket.assigns.store_id),
           {:ok, _} <- validate_path(path),
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
            notify_org(socket)
            {:reply, {:ok, %{store_seq: db_op.store_seq, hash: ref["hash"]}}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end
      else
        {:error, :store_archived} ->
          {:reply, {:error, %{reason: "store_archived"}}, socket}

        :error ->
          {:reply, {:error, %{reason: "invalid_base64"}}, socket}

        {:error, :limit_exceeded, info} ->
          {:reply, {:error, %{reason: "limit_exceeded"} |> Map.merge(info)}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      {:error, :rate_limited, info} ->
        {:reply, {:error, %{reason: "rate_limited", retry_after_ms: info.retry_after_ms}}, socket}

      {:error, {:missing_scope, _scope} = reason} ->
        {:reply, {:error, auth_error(reason)}, socket}

      {:error, :store_not_allowed = reason} ->
        {:reply, {:error, auth_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("rollback", %{"path" => path, "to_seq" => to_seq}, socket) do
    if authorize_current_store(socket, "entries:write") == :ok do
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
      {:reply, {:error, auth_error({:missing_scope, "entries:write"})}, socket}
    end
  end

  def handle_in("rollback", %{"to_seq" => to_seq}, socket) do
    if authorize_current_store(socket, "entries:write") == :ok do
      case Rollback.rollback_store(socket.assigns.store_id, to_seq) do
        {:ok, count} ->
          {:reply, {:ok, %{ops_written: count}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      {:reply, {:error, auth_error({:missing_scope, "entries:write"})}, socket}
    end
  end

  def handle_in("ack_seq", %{"seq" => seq}, socket) do
    socket = assign(socket, :last_acked_seq, seq)
    {:reply, :ok, socket}
  end

  def handle_in("status", _params, socket) do
    status = build_status(socket)
    {:reply, {:ok, status}, socket}
  end

  defp handle_write_op(params, socket) do
    case Map.get(@valid_ops, params["op"]) do
      nil ->
        {:reply, {:error, %{reason: "invalid op"}}, socket}

      op ->
        org = socket.assigns.store_token.organization

        # capver 3 wire shape: `path_segments` is authoritative.
        # `path` (slash-rendered string) is accepted as a fallback
        # for clients still on the canonical string form.
        with :ok <- verify_store_active(socket.assigns.store_id),
             {:ok, path} <- resolve_incoming_path(params),
             :ok <- validate_merge_value(op, params["value"]),
             :ok <- validate_if_match(op, params, socket),
             :ok <-
               check_billing_limits(
                 op,
                 Map.put(params, "path", path),
                 socket.assigns.store_id,
                 org
               ) do
          op_attrs =
            %{
              op: op,
              path: path,
              value: params["value"],
              device_id: socket.assigns.device_id,
              client_op_id: params["client_op_id"]
            }
            |> maybe_put_if_match(params)
            |> maybe_put_if_absent(params)
            |> maybe_put_fence(params)
            |> maybe_put_lease_fields(op, params)

          case Sync.write(socket.assigns.store_id, op_attrs) do
            # Idempotent lease release that matched nothing — no broadcast.
            {:ok, :noop} ->
              {:reply, {:ok, %{released: false}}, socket}

            {:ok, db_op} ->
              broadcast!(socket, "event", format_event(db_op))
              notify_org(socket)
              {:reply, {:ok, lease_aware_reply(db_op)}, socket}

            {:error, :conflict} ->
              {:reply, {:error, %{reason: "conflict"}}, socket}

            {:error, :held} ->
              {:reply, {:error, %{reason: "held"}}, socket}

            {:error, :occupied} ->
              {:reply, {:error, %{reason: "occupied"}}, socket}

            {:error, :not_held} ->
              {:reply, {:error, %{reason: "not_held"}}, socket}

            {:error, :fenced} ->
              {:reply, {:error, %{reason: "fenced"}}, socket}

            {:error, :exists} ->
              {:reply, {:error, %{reason: "exists"}}, socket}

            {:error, :invalid_precondition} ->
              {:reply, {:error, %{reason: "invalid_precondition"}}, socket}

            {:error, :if_match_unsupported_op} ->
              {:reply, {:error, %{reason: "if_match_unsupported_op", op: params["op"]}}, socket}

            {:error, :if_match_multi_leaf} ->
              {:reply, {:error, %{reason: "if_match_multi_leaf"}}, socket}

            {:error, :if_absent_unsupported_op} ->
              {:reply, {:error, %{reason: "if_absent_unsupported_op", op: params["op"]}}, socket}

            {:error, :if_absent_multi_leaf} ->
              {:reply, {:error, %{reason: "if_absent_multi_leaf"}}, socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: inspect(reason)}}, socket}
          end
        else
          {:error, :store_archived} ->
            {:reply, {:error, %{reason: "store_archived"}}, socket}

          {:error, :limit_exceeded, info} ->
            {:reply, {:error, %{reason: "limit_exceeded"} |> Map.merge(info)}, socket}

          {:error, {:if_match, details}} ->
            {:reply, {:error, details}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end
    end
  end

  # Validate the ONE if_match precondition that is specific to the channel
  # transport: capver must be >= 2 for CAS to be available. The remaining
  # CAS preconditions (op must be :set, value must be a leaf) are enforced
  # transport-agnostically inside `Dust.Sync.write/2` so HTTP and WebSocket
  # share the same error taxonomy.
  defp validate_if_match(_op, params, socket) do
    case Map.get(params, "if_match") do
      nil ->
        :ok

      _if_match ->
        capver = socket.assigns[:capver] || 1

        if capver < 2 do
          {:error, {:if_match, %{reason: "capver_mismatch"}}}
        else
          :ok
        end
    end
  end

  defp maybe_put_if_match(attrs, %{"if_match" => if_match}) when not is_nil(if_match) do
    Map.put(attrs, :if_match, if_match)
  end

  defp maybe_put_if_match(attrs, _params), do: attrs

  defp maybe_put_if_absent(attrs, %{"if_absent" => true}) do
    Map.put(attrs, :if_absent, true)
  end

  defp maybe_put_if_absent(attrs, _params), do: attrs

  # Opt-in fence on a non-lease write: `fence: %{"key" => ..., "token" => ...}`.
  defp maybe_put_fence(attrs, %{"fence" => %{"key" => key, "token" => token}})
       when is_binary(key) and is_integer(token) do
    Map.put(attrs, :fence, %{key: key, token: token})
  end

  defp maybe_put_fence(attrs, _params), do: attrs

  # Lease ops: acquire/renew need a ttl (default 30s); renew/release need the
  # caller's token. The server stamps the authoritative token + expires_at.
  defp maybe_put_lease_fields(attrs, op, params) when op in [:lease, :renew] do
    attrs
    |> Map.put(:ttl_ms, params["ttl_ms"] || 30_000)
    |> maybe_put_key(:holder, params["holder"])
    |> maybe_put_key(:token, params["token"])
  end

  defp maybe_put_lease_fields(attrs, :release, params) do
    maybe_put_key(attrs, :token, params["token"])
  end

  defp maybe_put_lease_fields(attrs, _op, _params), do: attrs

  defp maybe_put_key(attrs, _key, nil), do: attrs
  defp maybe_put_key(attrs, key, value), do: Map.put(attrs, key, value)

  # For :lease/:renew, surface the lease envelope (token/expires_at/holder) so
  # the client can build a %Dust.Lease{}. Other ops just get store_seq.
  defp lease_aware_reply(%{op: op, store_seq: seq, materialized_value: env})
       when op in [:lease, :renew] and is_map(env) do
    %{
      store_seq: seq,
      token: env["token"],
      expires_at: env["expires_at"],
      holder: env["holder"]
    }
  end

  defp lease_aware_reply(%{store_seq: seq}), do: %{store_seq: seq}

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
            path_segments: path_to_segments(op.path),
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
      # capver 3 wire shape: `path_segments` is authoritative.
      # `path` (slash-rendered string) is echoed for display + back-compat.
      path: op.path,
      path_segments: path_to_segments(op.path),
      value: value,
      device_id: op.device_id,
      client_op_id: op.client_op_id
    }
  end

  # Best-effort decode: returns `nil` if the stored path can't be
  # parsed back to segments, which shouldn't happen for canonical
  # paths but is defensive against malformed historical rows.
  defp path_to_segments(path) when is_binary(path) do
    case DustProtocol.Path.parse_rendered(path) do
      {:ok, segs} -> segs
      _ -> nil
    end
  end

  defp path_to_segments(_), do: nil

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

      state
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

  defp build_status(socket) do
    import Ecto.Query

    store_id = socket.assigns.store_id
    current_seq = Sync.current_seq(store_id)
    entry_count = Sync.entry_count(store_id)
    capabilities = AccessTokens.capabilities(socket.assigns.store_token, socket.assigns.store)

    store_meta =
      Dust.Repo.one(
        from(s in Dust.Stores.Store,
          where: s.id == ^store_id,
          select: %{
            op_count: s.op_count,
            file_storage_bytes: s.file_storage_bytes,
            expires_at: s.expires_at
          }
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
      expires_at: store_meta && store_meta.expires_at,
      permissions: capabilities.permissions,
      scopes: capabilities.scopes,
      store_access: capabilities.store_access,
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
  defp validate_path(path) when is_binary(path), do: DustProtocol.Path.parse_rendered(path)
  defp validate_path(_), do: {:error, :invalid_path}

  # Pull a canonical path string out of incoming wire params. Prefers
  # the authoritative `path_segments` array (capver 3) over the
  # legacy/compatibility `path` string.
  defp resolve_incoming_path(%{"path_segments" => segs}) when is_list(segs) do
    with {:ok, segments} <- DustProtocol.Path.from_segments(segs),
         {:ok, rendered} <- DustProtocol.Path.render(segments) do
      {:ok, rendered}
    end
  end

  defp resolve_incoming_path(%{"path" => path}) when is_binary(path) do
    with {:ok, _segments} <- DustProtocol.Path.parse_rendered(path) do
      {:ok, path}
    end
  end

  defp resolve_incoming_path(_), do: {:error, :missing_path}

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
    # Count net-new paths from merge using the canonical full-path
    # prefix. Path arrives canonical (slash-rendered) post-segment-first;
    # build child paths via segment-aware Path.child to handle dots /
    # slashes / tildes in child keys correctly.
    new_keys =
      case DustProtocol.Path.parse_rendered(path) do
        {:ok, prefix_segs} ->
          Enum.count(value, fn {key, _v} ->
            with {:ok, child_segs} <- DustProtocol.Path.child(prefix_segs, to_string(key)),
                 {:ok, child_path} <- DustProtocol.Path.render(child_segs) do
              Sync.get_entry(store_id, child_path) == nil
            else
              _ -> true
            end
          end)

        _ ->
          # Path failed to parse — treat every child as net-new; the
          # underlying write will fail anyway.
          map_size(value)
      end

    if new_keys > 0 do
      Dust.Billing.Limits.check_key_count(store_id, new_keys, org)
    else
      :ok
    end
  end

  defp check_billing_limits(_, _, _, _), do: :ok

  defp notify_org(socket) do
    org_slug = socket.assigns.store_token.organization.slug

    Phoenix.PubSub.broadcast(
      Dust.PubSub,
      "org_stores:#{org_slug}",
      {:store_changed, socket.assigns.store_id}
    )
  end

  defp authorize_current_store(socket, scope) do
    AccessTokens.authorize_store(socket.assigns.store_token, socket.assigns.store, scope)
  end

  defp auth_error({:missing_scope, scope}) do
    %{
      reason: "missing_scope",
      scope: scope,
      message: "Token is missing #{scope} scope"
    }
  end

  defp auth_error(:store_not_allowed) do
    %{
      reason: "store_not_allowed",
      message: "Token does not have access to this store"
    }
  end

  defp auth_error(_reason), do: %{reason: "unauthorized"}

  defp verify_store_active(store_id) do
    import Ecto.Query

    case Dust.Repo.one(from(s in Dust.Stores.Store, where: s.id == ^store_id, select: s.status)) do
      :active -> :ok
      _ -> {:error, :store_archived}
    end
  end

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
