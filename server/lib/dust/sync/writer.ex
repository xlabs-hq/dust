defmodule Dust.Sync.Writer do
  use GenServer

  alias Dust.Repo
  alias Dust.Sync.{StoreOp, StoreEntry}

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
          value: wrap_value(attrs[:value]),
          type: attrs[:type] || detect_type(attrs[:value]),
          device_id: attrs.device_id,
          client_op_id: attrs.client_op_id,
          store_id: store_id
        }
        |> Repo.insert!()

      # Apply to materialized state
      apply_to_entries(store_id, next_seq, attrs)

      op
    end)
  end

  defp apply_to_entries(store_id, seq, %{op: :set, path: path, value: value} = attrs) do
    type = attrs[:type] || detect_type(value)

    # Delete descendants
    {:ok, segments} = DustProtocol.Path.parse(path)
    delete_descendants(store_id, segments)

    # Upsert entry
    Repo.insert!(
      %StoreEntry{store_id: store_id, path: path, value: wrap_value(value), type: type, seq: seq},
      on_conflict: [set: [value: wrap_value(value), type: type, seq: seq]],
      conflict_target: [:store_id, :path]
    )
  end

  defp apply_to_entries(store_id, _seq, %{op: :delete, path: path}) do
    {:ok, segments} = DustProtocol.Path.parse(path)

    from(e in StoreEntry, where: e.store_id == ^store_id and e.path == ^path)
    |> Repo.delete_all()

    delete_descendants(store_id, segments)
  end

  defp apply_to_entries(store_id, seq, %{op: :merge, path: path, value: map}) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      child_path = "#{path}.#{key}"
      type = detect_type(value)

      Repo.insert!(
        %StoreEntry{
          store_id: store_id,
          path: child_path,
          value: wrap_value(value),
          type: type,
          seq: seq
        },
        on_conflict: [set: [value: wrap_value(value), type: type, seq: seq]],
        conflict_target: [:store_id, :path]
      )
    end)
  end

  defp apply_to_entries(store_id, seq, %{op: :increment, path: path, value: delta}) do
    current =
      case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
        nil -> 0
        entry -> unwrap_scalar(entry.value)
      end

    new_value = current + delta

    Repo.insert!(
      %StoreEntry{
        store_id: store_id,
        path: path,
        value: wrap_value(new_value),
        type: "counter",
        seq: seq
      },
      on_conflict: [set: [value: wrap_value(new_value), type: "counter", seq: seq]],
      conflict_target: [:store_id, :path]
    )
  end

  defp apply_to_entries(store_id, seq, %{op: :add, path: path, value: member}) do
    current_set =
      case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
        nil -> []
        entry -> unwrap_set(entry.value)
      end

    new_set = Enum.uniq([member | current_set])

    Repo.insert!(
      %StoreEntry{
        store_id: store_id,
        path: path,
        value: wrap_value(new_set),
        type: "set",
        seq: seq
      },
      on_conflict: [set: [value: wrap_value(new_set), type: "set", seq: seq]],
      conflict_target: [:store_id, :path]
    )
  end

  defp apply_to_entries(store_id, seq, %{op: :remove, path: path, value: member}) do
    current_set =
      case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
        nil -> []
        entry -> unwrap_set(entry.value)
      end

    new_set = List.delete(current_set, member)

    Repo.insert!(
      %StoreEntry{
        store_id: store_id,
        path: path,
        value: wrap_value(new_set),
        type: "set",
        seq: seq
      },
      on_conflict: [set: [value: wrap_value(new_set), type: "set", seq: seq]],
      conflict_target: [:store_id, :path]
    )
  end

  defp apply_to_entries(store_id, seq, %{op: :put_file, path: path, value: ref})
       when is_map(ref) do
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
  end

  defp delete_descendants(store_id, ancestor_segments) do
    prefix = Enum.join(ancestor_segments, ".") <> "."

    from(e in StoreEntry,
      where: e.store_id == ^store_id and like(e.path, ^"#{prefix}%")
    )
    |> Repo.delete_all()
  end

  defp detect_type(%Decimal{}), do: "decimal"
  defp detect_type(%DateTime{}), do: "datetime"
  defp detect_type(value) when is_map(value), do: "map"
  defp detect_type(value) when is_binary(value), do: "string"
  defp detect_type(value) when is_integer(value), do: "integer"
  defp detect_type(value) when is_float(value), do: "float"
  defp detect_type(value) when is_boolean(value), do: "boolean"
  defp detect_type(nil), do: "null"
  defp detect_type(_), do: "string"

  # StoreEntry.value is :map type, so wrap scalars.
  # Decimal and DateTime get a typed envelope for lossless round-tripping through jsonb.
  defp wrap_value(%Decimal{} = d), do: %{"_typed" => Decimal.to_string(d), "_type" => "decimal"}

  defp wrap_value(%DateTime{} = dt),
    do: %{"_typed" => DateTime.to_iso8601(dt), "_type" => "datetime"}

  defp wrap_value(value) when is_map(value), do: value
  defp wrap_value(value), do: %{"_scalar" => value}

  defp unwrap_scalar(%{"_scalar" => scalar}), do: scalar
  defp unwrap_scalar(value), do: value

  defp unwrap_set(%{"_scalar" => list}) when is_list(list), do: list
  defp unwrap_set(%{"_scalar" => _}), do: []
  defp unwrap_set(_), do: []
end
