defmodule Dust.Sync do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Sync.{Writer, StoreOp, StoreEntry}

  def write(store_id, op_attrs) do
    Writer.write(store_id, op_attrs)
  end

  def get_entry(store_id, path) do
    case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
      nil -> nil
      entry -> unwrap_entry(entry)
    end
  end

  def get_all_entries(store_id) do
    from(e in StoreEntry, where: e.store_id == ^store_id, order_by: e.path)
    |> Repo.all()
    |> Enum.map(&unwrap_entry/1)
  end

  def get_ops_since(store_id, since_seq) do
    from(o in StoreOp,
      where: o.store_id == ^store_id and o.store_seq > ^since_seq,
      order_by: [asc: o.store_seq]
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

  def entry_count(store_id) do
    from(e in StoreEntry,
      where: e.store_id == ^store_id,
      select: count()
    )
    |> Repo.one()
  end

  defp unwrap_entry(%StoreEntry{value: %{"_scalar" => scalar}} = entry) do
    %{entry | value: scalar}
  end

  defp unwrap_entry(entry), do: entry
end
