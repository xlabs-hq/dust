defmodule Dust.Sync do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Sync.{Writer, Rollback, StoreOp, StoreEntry, ValueCodec}

  def write(store_id, op_attrs) do
    Writer.write(store_id, op_attrs)
  catch
    :exit, reason -> {:error, {:writer_unavailable, reason}}
  end

  def get_entry(store_id, path) do
    case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
      nil ->
        # No direct entry — check for descendants (map was expanded into leaves)
        assemble_subtree(store_id, path)

      entry ->
        unwrap_entry(entry)
    end
  end

  defp assemble_subtree(store_id, path) do
    prefix = path <> "."

    descendants =
      from(e in StoreEntry,
        where: e.store_id == ^store_id and like(e.path, ^"#{prefix}%"),
        order_by: e.path
      )
      |> Repo.all()

    case descendants do
      [] ->
        nil

      entries ->
        # Build a nested map from leaf entries
        map =
          Enum.reduce(entries, %{}, fn entry, acc ->
            # Get the relative path after the prefix
            relative = String.replace_prefix(entry.path, prefix, "")
            keys = String.split(relative, ".")
            value = ValueCodec.unwrap(entry.value)
            put_nested(acc, keys, value)
          end)

        # Return a virtual entry with the assembled map
        %StoreEntry{
          store_id: store_id,
          path: path,
          value: map,
          type: "map",
          seq: Enum.max_by(entries, & &1.seq).seq
        }
    end
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, put_nested(child, rest, value))
  end

  def get_all_entries(store_id) do
    from(e in StoreEntry, where: e.store_id == ^store_id, order_by: e.path)
    |> Repo.all()
    |> Enum.map(&unwrap_entry/1)
  end

  @catch_up_batch_size 1000

  def get_ops_since(store_id, since_seq, opts \\ []) do
    limit = Keyword.get(opts, :limit, @catch_up_batch_size)

    from(o in StoreOp,
      where: o.store_id == ^store_id and o.store_seq > ^since_seq,
      order_by: [asc: o.store_seq],
      limit: ^limit
    )
    |> Repo.all()
  end

  def current_seq(store_id) do
    from(o in StoreOp,
      where: o.store_id == ^store_id,
      select: max(o.store_seq)
    )
    |> Repo.one() || 0
  end

  def get_entries_page(store_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(e in StoreEntry,
      where: e.store_id == ^store_id,
      order_by: e.path,
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&unwrap_entry/1)
  end

  def get_ops_page(store_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(o in StoreOp,
      where: o.store_id == ^store_id,
      order_by: [desc: o.store_seq],
      limit: ^limit
    )
    |> Repo.all()
  end

  def has_file_ref?(store_id, hash) do
    from(e in StoreEntry,
      where: e.store_id == ^store_id and e.type == "file",
      where: fragment("?->>'hash' = ?", e.value, ^hash),
      select: true,
      limit: 1
    )
    |> Repo.one()
    |> is_boolean()
  end

  def get_latest_snapshot(store_id) do
    from(s in Dust.Sync.StoreSnapshot,
      where: s.store_id == ^store_id,
      order_by: [desc: s.snapshot_seq],
      limit: 1
    )
    |> Repo.one()
  end

  def entry_count(store_id) do
    from(e in StoreEntry,
      where: e.store_id == ^store_id,
      select: count()
    )
    |> Repo.one()
  end

  @doc """
  Rollback a single path to its value at `to_seq`.

  Returns `{:ok, op}` or `{:ok, :noop}` if already at that state.
  """
  def rollback(store_id, path, to_seq) do
    Rollback.rollback_path(store_id, path, to_seq)
  end

  @doc """
  Rollback the entire store to its state at `to_seq`.

  Returns `{:ok, count}` where count is the number of ops written.
  """
  def rollback(store_id, to_seq) do
    Rollback.rollback_store(store_id, to_seq)
  end

  defp unwrap_entry(%StoreEntry{} = entry) do
    %{entry | value: ValueCodec.unwrap(entry.value)}
  end
end
