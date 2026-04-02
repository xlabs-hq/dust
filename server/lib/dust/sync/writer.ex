defmodule Dust.Sync.Writer do
  use GenServer

  alias Dust.Repo
  alias Dust.Sync.{StoreOp, StoreEntry, ValueCodec}

  import Ecto.Query

  @idle_timeout :timer.minutes(15)

  def start_link(store_id) do
    GenServer.start_link(__MODULE__, store_id, name: via(store_id))
  end

  def write(store_id, op_attrs) do
    pid = ensure_started(store_id)
    GenServer.call(pid, {:write, op_attrs})
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
    {:ok, %{store_id: store_id}, @idle_timeout}
  end

  @impl true
  def handle_call({:write, op_attrs}, _from, state) do
    result = do_write(state.store_id, op_attrs)
    {:reply, result, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  defp do_write(store_id, attrs) do
    metadata = %{store_id: store_id, op: attrs.op, path: attrs.path}

    :telemetry.span([:dust, :write], metadata, fn ->
      result =
        Repo.transaction(fn ->
          # Get current max store_seq
          current_seq =
            from(o in StoreOp,
              where: o.store_id == ^store_id,
              select: max(o.store_seq)
            )
            |> Repo.one() || 0

          next_seq = current_seq + 1

          # Insert op
          op =
            %StoreOp{
              store_seq: next_seq,
              op: attrs.op,
              path: attrs.path,
              value: ValueCodec.wrap(attrs[:value]),
              type: attrs[:type] || ValueCodec.detect_type(attrs[:value]),
              device_id: attrs.device_id,
              client_op_id: attrs.client_op_id,
              store_id: store_id
            }
            |> Repo.insert!()

          # Apply to materialized state and attach the result to the op
          materialized = apply_to_entries(store_id, next_seq, attrs)

          %{op | materialized_value: materialized}
        end)

      {result, metadata}
    end)
  end

  defp apply_to_entries(store_id, seq, %{op: :set, path: path, value: value} = attrs) do
    # Decrement file ref if overwriting a file entry
    decrement_file_ref_at(store_id, path)

    # Delete descendants (also decrements their file refs)
    {:ok, segments} = DustProtocol.Path.parse(path)
    delete_descendants(store_id, segments)

    # If value is a plain map, expand into leaf entries recursively.
    # Typed values (Decimal, DateTime, file refs) are stored as-is.
    if is_map(value) and not ValueCodec.typed_value?(value) do
      leaves = ValueCodec.flatten_map(path, value)

      Enum.each(leaves, fn {leaf_path, leaf_value} ->
        type = attrs[:type] || ValueCodec.detect_type(leaf_value)

        Repo.insert!(
          %StoreEntry{
            store_id: store_id,
            path: leaf_path,
            value: ValueCodec.wrap(leaf_value),
            type: type,
            seq: seq
          },
          on_conflict: [set: [value: ValueCodec.wrap(leaf_value), type: type, seq: seq]],
          conflict_target: [:store_id, :path]
        )
      end)

      # Also delete the parent path entry if it existed as a scalar
      from(e in StoreEntry, where: e.store_id == ^store_id and e.path == ^path)
      |> Repo.delete_all()
    else
      type = attrs[:type] || ValueCodec.detect_type(value)

      Repo.insert!(
        %StoreEntry{store_id: store_id, path: path, value: ValueCodec.wrap(value), type: type, seq: seq},
        on_conflict: [set: [value: ValueCodec.wrap(value), type: type, seq: seq]],
        conflict_target: [:store_id, :path]
      )
    end

    value
  end

  defp apply_to_entries(store_id, _seq, %{op: :delete, path: path}) do
    # Decrement file ref if deleting a file entry
    decrement_file_ref_at(store_id, path)

    {:ok, segments} = DustProtocol.Path.parse(path)

    from(e in StoreEntry, where: e.store_id == ^store_id and e.path == ^path)
    |> Repo.delete_all()

    # Also decrements file refs for descendants
    delete_descendants(store_id, segments)
    nil
  end

  defp apply_to_entries(store_id, seq, %{op: :merge, path: path, value: map}) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      child_path = "#{path}.#{key}"

      if is_map(value) and not ValueCodec.typed_value?(value) do
        # Expanding a nested map — remove stale descendants first
        decrement_file_ref_at(store_id, child_path)
        {:ok, segs} = DustProtocol.Path.parse(child_path)
        delete_descendants(store_id, segs)

        # Delete the direct entry if it exists (replaced by leaves)
        from(e in StoreEntry, where: e.store_id == ^store_id and e.path == ^child_path)
        |> Repo.delete_all()

        leaves = ValueCodec.flatten_map(child_path, value)

        Enum.each(leaves, fn {leaf_path, leaf_value} ->
          type = ValueCodec.detect_type(leaf_value)

          Repo.insert!(
            %StoreEntry{
              store_id: store_id,
              path: leaf_path,
              value: ValueCodec.wrap(leaf_value),
              type: type,
              seq: seq
            },
            on_conflict: [set: [value: ValueCodec.wrap(leaf_value), type: type, seq: seq]],
            conflict_target: [:store_id, :path]
          )
        end)
      else
        type = ValueCodec.detect_type(value)

        Repo.insert!(
          %StoreEntry{
            store_id: store_id,
            path: child_path,
            value: ValueCodec.wrap(value),
            type: type,
            seq: seq
          },
          on_conflict: [set: [value: ValueCodec.wrap(value), type: type, seq: seq]],
          conflict_target: [:store_id, :path]
        )
      end
    end)

    map
  end

  defp apply_to_entries(store_id, seq, %{op: :increment, path: path, value: delta}) do
    current =
      case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
        nil -> 0
        entry -> ValueCodec.unwrap(entry.value)
      end

    new_value = current + delta

    Repo.insert!(
      %StoreEntry{
        store_id: store_id,
        path: path,
        value: ValueCodec.wrap(new_value),
        type: "counter",
        seq: seq
      },
      on_conflict: [set: [value: ValueCodec.wrap(new_value), type: "counter", seq: seq]],
      conflict_target: [:store_id, :path]
    )

    new_value
  end

  defp apply_to_entries(store_id, seq, %{op: :add, path: path, value: member}) do
    current_set =
      case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
        nil -> []
        entry -> ValueCodec.unwrap_set(entry.value)
      end

    new_set = Enum.uniq([member | current_set])

    Repo.insert!(
      %StoreEntry{
        store_id: store_id,
        path: path,
        value: ValueCodec.wrap(new_set),
        type: "set",
        seq: seq
      },
      on_conflict: [set: [value: ValueCodec.wrap(new_set), type: "set", seq: seq]],
      conflict_target: [:store_id, :path]
    )

    new_set
  end

  defp apply_to_entries(store_id, seq, %{op: :remove, path: path, value: member}) do
    current_set =
      case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
        nil -> []
        entry -> ValueCodec.unwrap_set(entry.value)
      end

    new_set = List.delete(current_set, member)

    Repo.insert!(
      %StoreEntry{
        store_id: store_id,
        path: path,
        value: ValueCodec.wrap(new_set),
        type: "set",
        seq: seq
      },
      on_conflict: [set: [value: ValueCodec.wrap(new_set), type: "set", seq: seq]],
      conflict_target: [:store_id, :path]
    )

    new_set
  end

  defp apply_to_entries(store_id, seq, %{op: :put_file, path: path, value: ref})
       when is_map(ref) do
    # Decrement old file ref if overwriting
    decrement_file_ref_at(store_id, path)

    {:ok, segments} = DustProtocol.Path.parse(path)
    delete_descendants(store_id, segments)

    Repo.insert!(
      %StoreEntry{
        store_id: store_id,
        path: path,
        value: ref,
        type: "file",
        seq: seq
      },
      on_conflict: [set: [value: ref, type: "file", seq: seq]],
      conflict_target: [:store_id, :path]
    )

    ref
  end

  defp delete_descendants(store_id, ancestor_segments) do
    prefix = Enum.join(ancestor_segments, ".") <> "."

    # Decrement file refs before deleting
    decrement_file_refs(store_id, prefix)

    from(e in StoreEntry,
      where: e.store_id == ^store_id and like(e.path, ^"#{prefix}%")
    )
    |> Repo.delete_all()
  end

  # Decrement reference_count for any file blobs referenced by entries
  # that are about to be overwritten or deleted at a specific path.
  defp decrement_file_ref_at(store_id, path) do
    case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
      %StoreEntry{type: "file", value: %{"hash" => hash}} ->
        Dust.Files.decrement_ref(hash)

      _ ->
        :ok
    end
  end

  # Decrement refs for all file entries under a prefix (descendants).
  defp decrement_file_refs(store_id, prefix) do
    from(e in StoreEntry,
      where: e.store_id == ^store_id and e.type == "file" and like(e.path, ^"#{prefix}%"),
      select: e.value
    )
    |> Repo.all()
    |> Enum.each(fn
      %{"hash" => hash} -> Dust.Files.decrement_ref(hash)
      _ -> :ok
    end)
  end

end
