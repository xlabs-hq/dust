defmodule Dust.Sync.Writer do
  use GenServer

  alias Dust.Sync.{StoreDB, ValueCodec}
  alias DustProtocol.Path

  @idle_timeout :timer.minutes(15)

  def start_link(store_id) do
    GenServer.start_link(__MODULE__, store_id, name: via(store_id))
  end

  def write(store_id, op_attrs) do
    pid = ensure_started(store_id)
    GenServer.call(pid, {:write, op_attrs})
  end

  def batch_write(store_id, ops_attrs) when is_list(ops_attrs) do
    pid = ensure_started(store_id)
    GenServer.call(pid, {:batch_write, ops_attrs})
  end

  def stop(store_id) do
    case Registry.lookup(Dust.Sync.WriterRegistry, store_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  def compact(store_id) do
    pid = ensure_started(store_id)
    GenServer.call(pid, :compact, :timer.minutes(5))
  end

  def via(store_id) do
    {:via, Registry, {Dust.Sync.WriterRegistry, store_id}}
  end

  defp ensure_started(store_id) do
    case Registry.lookup(Dust.Sync.WriterRegistry, store_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               Dust.Sync.WriterSupervisor,
               {__MODULE__, store_id}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  # Server callbacks

  @impl true
  def init(store_id) do
    case StoreDB.write_conn(store_id) do
      {:ok, db} ->
        {:ok, %{store_id: store_id, db: db}, @idle_timeout}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:write, op_attrs}, _from, state) do
    result = do_write(state, op_attrs)
    {:reply, result, state, @idle_timeout}
  end

  @impl true
  def handle_call({:batch_write, ops_attrs}, _from, state) do
    result = do_batch_write(state, ops_attrs)
    {:reply, result, state, @idle_timeout}
  end

  @impl true
  def handle_call(:compact, _from, state) do
    result = do_compact(state.db)
    {:reply, result, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    Exqlite.Sqlite3.close(state.db)
    {:stop, :normal, state}
  end

  defp do_write(state, attrs) do
    %{store_id: store_id, db: db} = state
    metadata = %{store_id: store_id, op: attrs.op, path: attrs.path}

    :telemetry.span([:dust, :write], metadata, fn ->
      # The inner function returns either the op map (on success) or
      # `{:error, reason}` on CAS conflict. `sqlite_transaction/2` wraps
      # the success in `{:ok, _}` and rolls back + propagates the error
      # unchanged on `{:error, _}`.
      result =
        sqlite_transaction(db, fn ->
          # Get current max store_seq from ops AND snapshots
          ops_seq = query_one_int(db, "SELECT max(store_seq) FROM store_ops")
          snap_seq = query_one_int(db, "SELECT max(snapshot_seq) FROM store_snapshots")
          current_seq = max(ops_seq, snap_seq)
          next_seq = current_seq + 1

          if attrs.op in [:lease, :renew, :release] do
            apply_lease_op(db, next_seq, attrs, store_id)
          else
            with :ok <- maybe_validate_if_match(db, attrs.path, attrs),
                 :ok <- maybe_validate_if_absent(db, attrs.path, attrs),
                 :ok <- maybe_validate_fence(db, attrs) do
              insert_and_apply(db, next_seq, attrs, store_id)
            end
          end
        end)

      # Update cached metadata in Postgres (best-effort, after durable commit)
      case result do
        # No-op release (token didn't match): nothing committed, nothing to broadcast.
        {:ok, :noop} ->
          {result, metadata}

        {:ok, op} ->
          update_store_metadata(store_id, op.store_seq, db, 1)
          {result, metadata}

        _ ->
          {result, metadata}
      end
    end)
  end

  defp do_batch_write(state, ops_attrs) do
    %{store_id: store_id, db: db} = state
    metadata = %{store_id: store_id, batch_size: length(ops_attrs)}

    :telemetry.span([:dust, :batch_write], metadata, fn ->
      result =
        sqlite_transaction(db, fn ->
          ops_seq = query_one_int(db, "SELECT max(store_seq) FROM store_ops")
          snap_seq = query_one_int(db, "SELECT max(snapshot_seq) FROM store_snapshots")
          start_seq = max(ops_seq, snap_seq)

          ops_attrs
          |> Enum.with_index()
          |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
            next_seq = start_seq + index + 1

            with :ok <- maybe_validate_if_match(db, attrs.path, attrs),
                 :ok <- maybe_validate_if_absent(db, attrs.path, attrs) do
              op = insert_and_apply(db, next_seq, attrs, store_id)
              {:cont, {:ok, [op | acc]}}
            else
              {:error, reason} ->
                # Annotate the failure with which op in the batch caused
                # it so the caller can render a precise error.
                {:halt, {:error, {reason, index, attrs.path}}}
            end
          end)
          |> case do
            {:ok, ops} -> Enum.reverse(ops)
            err -> err
          end
        end)

      case result do
        {:ok, ops} when is_list(ops) ->
          last = List.last(ops)
          if last, do: update_store_metadata(store_id, last.store_seq, db, length(ops))
          {{:ok, ops}, Map.put(metadata, :ops_committed, length(ops))}

        _ ->
          {result, metadata}
      end
    end)
  end

  defp insert_and_apply(db, next_seq, attrs, store_id) do
    # Insert op
    value_json = encode_value(attrs[:value])
    type = attrs[:type] || ValueCodec.detect_type(attrs[:value])

    exec(
      db,
      """
        INSERT INTO store_ops (store_seq, op, path, value, type, device_id, client_op_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        next_seq,
        to_string(attrs.op),
        attrs.path,
        value_json,
        type,
        attrs.device_id,
        attrs.client_op_id
      ]
    )

    # Apply to materialized state
    materialized = apply_to_entries(db, next_seq, attrs)

    %{
      store_seq: next_seq,
      op: attrs.op,
      path: attrs.path,
      value: ValueCodec.wrap(attrs[:value]),
      type: type,
      device_id: attrs.device_id,
      client_op_id: attrs.client_op_id,
      store_id: store_id,
      materialized_value: materialized
    }
  end

  defp maybe_validate_if_match(db, path, attrs) do
    case fetch_if_match(attrs) do
      nil ->
        :ok

      expected when is_integer(expected) ->
        case query_one(db, "SELECT seq FROM store_entries WHERE path = ?", [path]) do
          ^expected -> :ok
          _ -> {:error, :conflict}
        end
    end
  end

  defp fetch_if_match(attrs) do
    attrs[:if_match] || attrs["if_match"]
  end

  # --- Leases (lease-as-entry, typed "lease" value; lazy expiry + atomic steal) ---
  #
  # The lease envelope is `%{"_type" => "lease", "holder" =>, "token" =>,
  # "expires_at" =>}`. `token` = the acquiring op's store_seq (monotonic,
  # preserved across renew, bumped only on a fresh acquire/steal). All
  # validation + the server clock are evaluated inside the write transaction,
  # so concurrent claims cannot both win.

  defp apply_lease_op(db, seq, %{op: :lease, path: path} = attrs, store_id) do
    now = System.system_time(:millisecond)

    case read_lease(db, path, now) do
      state when state in [:absent, :expired] ->
        envelope = %{
          "_type" => "lease",
          "holder" => attrs[:holder],
          "token" => seq,
          "expires_at" => now + attrs.ttl_ms
        }

        attrs = attrs |> Map.put(:value, envelope) |> Map.put(:type, "lease")
        insert_and_apply(db, seq, attrs, store_id)

      :live ->
        {:error, :held}

      :occupied ->
        {:error, :occupied}
    end
  end

  defp apply_lease_op(db, seq, %{op: :renew, path: path, token: token} = attrs, store_id) do
    now = System.system_time(:millisecond)

    case read_lease(db, path, now, with_value: true) do
      {:live, %{"token" => ^token} = envelope} ->
        # Keep the original token; only extend expiry.
        renewed = Map.put(envelope, "expires_at", now + attrs.ttl_ms)
        attrs = attrs |> Map.put(:value, renewed) |> Map.put(:type, "lease")
        insert_and_apply(db, seq, attrs, store_id)

      _ ->
        {:error, :not_held}
    end
  end

  defp apply_lease_op(db, seq, %{op: :release, path: path, token: token} = attrs, store_id) do
    now = System.system_time(:millisecond)

    case read_lease(db, path, now, with_value: true) do
      {state, %{"token" => ^token}} when state in [:live, :expired] ->
        attrs = Map.put(attrs, :value, nil)
        insert_and_apply(db, seq, attrs, store_id)

      _ ->
        # Already released, stolen, or never held by this token — idempotent no-op.
        :noop
    end
  end

  # Returns :absent | :live | :expired | :occupied, or (with_value: true)
  # {:live | :expired, envelope} | :absent | :occupied.
  defp read_lease(db, path, now, opts \\ []) do
    case query_row(db, "SELECT value, type FROM store_entries WHERE path = ?", [path]) do
      nil ->
        :absent

      [json, "lease"] ->
        envelope = Jason.decode!(json)
        exp = envelope["expires_at"]
        state = if is_integer(exp) and exp <= now, do: :expired, else: :live
        if opts[:with_value], do: {state, envelope}, else: state

      [_json, _other_type] ->
        :occupied
    end
  end

  # Opt-in fencing for non-lease writes: `fence: %{key, token}` (or a
  # `%Dust.Lease{}`-shaped map). The write applies only if `key` still holds a
  # LIVE lease with that token; otherwise the holder has lost it → `:fenced`.
  defp maybe_validate_fence(db, attrs) do
    case attrs[:fence] || attrs["fence"] do
      nil ->
        :ok

      fence ->
        now = System.system_time(:millisecond)
        key = fence[:key] || fence["key"]
        token = fence[:token] || fence["token"]

        case read_lease(db, key, now, with_value: true) do
          {:live, %{"token" => ^token}} -> :ok
          _ -> {:error, :fenced}
        end
    end
  end

  # `if_absent` claims a key only when no entry exists for the path. The
  # check runs inside the same transaction as the insert, so two concurrent
  # claims can't both win.
  defp maybe_validate_if_absent(db, path, attrs) do
    if attrs[:if_absent] || attrs["if_absent"] do
      case query_one(db, "SELECT seq FROM store_entries WHERE path = ?", [path]) do
        nil -> :ok
        _seq -> {:error, :exists}
      end
    else
      :ok
    end
  end

  defp do_compact(db) do
    max_seq = query_one_int(db, "SELECT max(store_seq) FROM store_ops")

    if max_seq > 0 do
      result =
        sqlite_transaction(db, fn ->
          entries = query_all(db, "SELECT path, value, type FROM store_entries", [])

          snapshot_data =
            Map.new(entries, fn [path, value, type] ->
              {path, %{"value" => Jason.decode!(value), "type" => type}}
            end)

          exec(db, "INSERT INTO store_snapshots (snapshot_seq, snapshot_data) VALUES (?, ?)", [
            max_seq,
            Jason.encode!(snapshot_data)
          ])

          exec(db, "DELETE FROM store_ops WHERE store_seq <= ?", [max_seq])
          exec(db, "DELETE FROM store_snapshots WHERE snapshot_seq < ?", [max_seq])

          max_seq
        end)

      case result do
        {:ok, _} -> Exqlite.Sqlite3.execute(db, "VACUUM")
        _ -> :ok
      end

      result
    else
      {:ok, :no_ops}
    end
  end

  # --- Apply to entries (SQLite) ---

  # `path` arrives at the writer as a canonical rendered slash string
  # (Sync.write/2 normalizes inputs before getting here). Internal
  # segment work goes through DustProtocol.Path; child paths are
  # constructed via Path.child/2 so literal `.` / `/` in keys survive.

  defp apply_to_entries(db, seq, %{op: :set, path: path, value: value} = attrs) do
    decrement_file_ref_at(db, path)

    {:ok, segments} = Path.parse_rendered(path)
    delete_descendants(db, segments)

    if is_map(value) and not ValueCodec.typed_value?(value) do
      leaves = ValueCodec.flatten_map(path, value)

      Enum.each(leaves, fn {leaf_path, leaf_value} ->
        type = attrs[:type] || ValueCodec.detect_type(leaf_value)
        upsert_entry(db, leaf_path, ValueCodec.wrap(leaf_value), type, seq)
      end)

      exec(db, "DELETE FROM store_entries WHERE path = ?", [path])
    else
      type = attrs[:type] || ValueCodec.detect_type(value)
      upsert_entry(db, path, ValueCodec.wrap(value), type, seq)
    end

    value
  end

  defp apply_to_entries(db, _seq, %{op: :delete, path: path}) do
    decrement_file_ref_at(db, path)
    {:ok, segments} = Path.parse_rendered(path)
    exec(db, "DELETE FROM store_entries WHERE path = ?", [path])
    delete_descendants(db, segments)
    nil
  end

  defp apply_to_entries(db, seq, %{op: :merge, path: path, value: map}) when is_map(map) do
    {:ok, prefix_segments} = Path.parse_rendered(path)

    Enum.each(map, fn {key, value} ->
      {:ok, child_segments} = Path.child(prefix_segments, to_string(key))
      {:ok, child_path} = Path.render(child_segments)

      if is_map(value) and not ValueCodec.typed_value?(value) do
        decrement_file_ref_at(db, child_path)
        delete_descendants(db, child_segments)
        exec(db, "DELETE FROM store_entries WHERE path = ?", [child_path])

        leaves = ValueCodec.flatten_map(child_path, value)

        Enum.each(leaves, fn {leaf_path, leaf_value} ->
          type = ValueCodec.detect_type(leaf_value)
          upsert_entry(db, leaf_path, ValueCodec.wrap(leaf_value), type, seq)
        end)
      else
        type = ValueCodec.detect_type(value)
        upsert_entry(db, child_path, ValueCodec.wrap(value), type, seq)
      end
    end)

    map
  end

  defp apply_to_entries(db, seq, %{op: :increment, path: path, value: delta}) do
    current = read_entry_value(db, path) || 0
    new_value = current + delta
    upsert_entry(db, path, ValueCodec.wrap(new_value), "counter", seq)
    new_value
  end

  defp apply_to_entries(db, seq, %{op: :add, path: path, value: member}) do
    current_set = read_set_value(db, path)
    new_set = Enum.uniq([member | current_set])
    upsert_entry(db, path, ValueCodec.wrap(new_set), "set", seq)
    new_set
  end

  defp apply_to_entries(db, seq, %{op: :remove, path: path, value: member}) do
    current_set = read_set_value(db, path)
    new_set = List.delete(current_set, member)
    upsert_entry(db, path, ValueCodec.wrap(new_set), "set", seq)
    new_set
  end

  defp apply_to_entries(db, seq, %{op: :put_file, path: path, value: ref}) when is_map(ref) do
    decrement_file_ref_at(db, path)
    {:ok, segments} = Path.parse_rendered(path)
    delete_descendants(db, segments)
    upsert_entry(db, path, ref, "file", seq)
    ref
  end

  # Acquire/steal and renew both upsert the (server-constructed) lease envelope.
  defp apply_to_entries(db, seq, %{op: op, path: path, value: envelope})
       when op in [:lease, :renew] do
    upsert_entry(db, path, envelope, "lease", seq)
    envelope
  end

  # Release deletes the lease entry (token already validated by apply_lease_op).
  defp apply_to_entries(db, _seq, %{op: :release, path: path}) do
    exec(db, "DELETE FROM store_entries WHERE path = ?", [path])
    nil
  end

  # --- SQLite helpers ---

  defp upsert_entry(db, path, value, type, seq) do
    exec(
      db,
      """
        INSERT OR REPLACE INTO store_entries (path, value, type, seq)
        VALUES (?, ?, ?, ?)
      """,
      [path, Jason.encode!(value), type, seq]
    )
  end

  defp delete_descendants(db, ancestor_segments) do
    {:ok, prefix} = Path.render_descendant_prefix(ancestor_segments)
    decrement_file_refs(db, prefix)

    exec(
      db,
      ~s|DELETE FROM store_entries WHERE path LIKE ? ESCAPE '\\'|,
      ["#{Dust.Sync.escape_like(prefix)}%"]
    )
  end

  defp read_entry_value(db, path) do
    case query_one(db, "SELECT value FROM store_entries WHERE path = ?", [path]) do
      nil -> nil
      json -> json |> Jason.decode!() |> ValueCodec.unwrap()
    end
  end

  defp read_set_value(db, path) do
    case query_one(db, "SELECT value FROM store_entries WHERE path = ?", [path]) do
      nil -> []
      json -> json |> Jason.decode!() |> ValueCodec.unwrap_set()
    end
  end

  defp decrement_file_ref_at(db, path) do
    case query_row(db, "SELECT value, type FROM store_entries WHERE path = ?", [path]) do
      [json, "file"] ->
        case Jason.decode!(json) do
          %{"hash" => hash} -> Dust.Files.decrement_ref(hash)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp decrement_file_refs(db, prefix) do
    rows =
      query_all(
        db,
        ~s|SELECT value FROM store_entries WHERE type = 'file' AND path LIKE ? ESCAPE '\\'|,
        ["#{Dust.Sync.escape_like(prefix)}%"]
      )

    Enum.each(rows, fn [json] ->
      case Jason.decode!(json) do
        %{"hash" => hash} -> Dust.Files.decrement_ref(hash)
        _ -> :ok
      end
    end)
  end

  defp encode_value(nil), do: nil
  defp encode_value(value), do: Jason.encode!(ValueCodec.wrap(value))

  # Update cached metadata in Postgres stores table. `inc_by` is the
  # number of ops committed in this transaction — 1 for the normal
  # write path, N for batch_write — so the cached op_count stays in
  # sync with the actual store_ops row count.
  defp update_store_metadata(store_id, current_seq, db, inc_by)
       when is_integer(inc_by) and inc_by > 0 do
    import Ecto.Query

    entry_count = query_one_int(db, "SELECT count(*) FROM store_entries")

    Dust.Repo.update_all(
      from(s in Dust.Stores.Store, where: s.id == ^store_id),
      set: [current_seq: current_seq, entry_count: entry_count],
      inc: [op_count: inc_by]
    )
  end

  # Single centralized rescue point for SQLite NIF boundary.
  # All transactional work goes through this helper.
  #
  # If the inner function returns `{:error, _}`, the transaction is rolled
  # back and the error is returned unchanged. Any other return value is
  # committed and wrapped in `{:ok, result}`. Raised exceptions also
  # trigger a rollback.
  defp sqlite_transaction(db, fun) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

    try do
      case fun.() do
        {:error, _} = error ->
          :ok = Exqlite.Sqlite3.execute(db, "ROLLBACK")
          error

        result ->
          :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
          {:ok, result}
      end
    rescue
      e ->
        Exqlite.Sqlite3.execute(db, "ROLLBACK")
        {:error, e}
    end
  end

  # --- Low-level Exqlite wrappers ---

  defp exec(db, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    :ok
  end

  defp query_one(db, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)

    result =
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, [val]} -> val
        :done -> nil
      end

    :ok = Exqlite.Sqlite3.release(db, stmt)
    result
  end

  defp query_one_int(db, sql) do
    case query_one(db, sql) do
      nil -> 0
      val when is_integer(val) -> val
      _ -> 0
    end
  end

  defp query_row(db, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)

    result =
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, row} -> row
        :done -> nil
      end

    :ok = Exqlite.Sqlite3.release(db, stmt)
    result
  end

  defp query_all(db, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = collect_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    rows
  end

  defp collect_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> collect_rows(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
