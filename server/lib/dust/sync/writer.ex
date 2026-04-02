defmodule Dust.Sync.Writer do
  use GenServer

  alias Dust.Sync.{StoreDB, ValueCodec}

  @idle_timeout :timer.minutes(15)

  def start_link(store_id) do
    GenServer.start_link(__MODULE__, store_id, name: via(store_id))
  end

  def write(store_id, op_attrs) do
    pid = ensure_started(store_id)
    GenServer.call(pid, {:write, op_attrs})
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
      result =
        sqlite_transaction(db, fn ->
          # Get current max store_seq from ops AND snapshots
          ops_seq = query_one_int(db, "SELECT max(store_seq) FROM store_ops")
          snap_seq = query_one_int(db, "SELECT max(snapshot_seq) FROM store_snapshots")
          current_seq = max(ops_seq, snap_seq)
          next_seq = current_seq + 1

          # Insert op
          value_json = encode_value(attrs[:value])
          type = attrs[:type] || ValueCodec.detect_type(attrs[:value])

          exec(db, """
            INSERT INTO store_ops (store_seq, op, path, value, type, device_id, client_op_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          """, [next_seq, to_string(attrs.op), attrs.path, value_json, type, attrs.device_id, attrs.client_op_id])

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
        end)

      # Update cached metadata in Postgres (best-effort, after durable commit)
      case result do
        {:ok, op} ->
          update_store_metadata(store_id, op.store_seq, db)
          {result, metadata}

        _ ->
          {result, metadata}
      end
    end)
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

          exec(db, "INSERT INTO store_snapshots (snapshot_seq, snapshot_data) VALUES (?, ?)",
            [max_seq, Jason.encode!(snapshot_data)])

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

  defp apply_to_entries(db, seq, %{op: :set, path: path, value: value} = attrs) do
    decrement_file_ref_at(db, path)

    {:ok, segments} = DustProtocol.Path.parse(path)
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
    {:ok, segments} = DustProtocol.Path.parse(path)
    exec(db, "DELETE FROM store_entries WHERE path = ?", [path])
    delete_descendants(db, segments)
    nil
  end

  defp apply_to_entries(db, seq, %{op: :merge, path: path, value: map}) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      child_path = "#{path}.#{key}"

      if is_map(value) and not ValueCodec.typed_value?(value) do
        decrement_file_ref_at(db, child_path)
        {:ok, segs} = DustProtocol.Path.parse(child_path)
        delete_descendants(db, segs)
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
    {:ok, segments} = DustProtocol.Path.parse(path)
    delete_descendants(db, segments)
    upsert_entry(db, path, ref, "file", seq)
    ref
  end

  # --- SQLite helpers ---

  defp upsert_entry(db, path, value, type, seq) do
    exec(db, """
      INSERT OR REPLACE INTO store_entries (path, value, type, seq)
      VALUES (?, ?, ?, ?)
    """, [path, Jason.encode!(value), type, seq])
  end

  defp delete_descendants(db, ancestor_segments) do
    prefix = Enum.join(ancestor_segments, ".") <> "."
    decrement_file_refs(db, prefix)
    exec(db, "DELETE FROM store_entries WHERE path LIKE ?", ["#{prefix}%"])
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
    rows = query_all(db, "SELECT value FROM store_entries WHERE type = 'file' AND path LIKE ?", ["#{prefix}%"])

    Enum.each(rows, fn [json] ->
      case Jason.decode!(json) do
        %{"hash" => hash} -> Dust.Files.decrement_ref(hash)
        _ -> :ok
      end
    end)
  end

  defp encode_value(nil), do: nil
  defp encode_value(value), do: Jason.encode!(ValueCodec.wrap(value))

  # Update cached metadata in Postgres stores table
  defp update_store_metadata(store_id, current_seq, db) do
    import Ecto.Query

    entry_count = query_one_int(db, "SELECT count(*) FROM store_entries")

    Dust.Repo.update_all(
      from(s in Dust.Stores.Store, where: s.id == ^store_id),
      set: [current_seq: current_seq, entry_count: entry_count],
      inc: [op_count: 1]
    )
  end

  # Single centralized rescue point for SQLite NIF boundary.
  # All transactional work goes through this helper.
  defp sqlite_transaction(db, fun) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

    try do
      result = fun.()
      :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
      {:ok, result}
    rescue
      e ->
        Exqlite.Sqlite3.execute(db, "ROLLBACK")
        {:error, e}
    end
  end

  # --- Low-level Exqlite wrappers ---

  defp exec(db, sql, params \\ []) do
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
