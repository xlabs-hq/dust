defmodule Dust.Cache.Ecto do
  @behaviour Dust.Cache

  import Ecto.Query

  alias Dust.Cache.Ecto.CacheEntry

  @seq_sentinel_path "_dust:last_seq"

  @impl Dust.Cache
  def read(repo, store, path) do
    query =
      from(c in CacheEntry,
        where: c.store == ^store and c.path == ^path,
        select: c.value
      )

    case repo.one(query) do
      nil -> :miss
      json -> {:ok, Jason.decode!(json)}
    end
  end

  @impl Dust.Cache
  def read_all(repo, store, pattern) do
    compiled = Dust.Protocol.Glob.compile(pattern)

    query =
      from(c in CacheEntry,
        where: c.store == ^store and c.path != ^@seq_sentinel_path,
        select: {c.path, c.value}
      )

    repo.all(query)
    |> Enum.filter(fn {path, _} ->
      Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
    end)
    |> Enum.map(fn {path, json} -> {path, Jason.decode!(json)} end)
  end

  @impl Dust.Cache
  def write(repo, store, path, value, type, seq) do
    entry = %{
      store: store,
      path: path,
      value: Jason.encode!(value),
      type: type,
      seq: seq
    }

    repo.insert_all(CacheEntry, [entry],
      on_conflict: [set: [value: entry.value, type: entry.type, seq: entry.seq]],
      conflict_target: [:store, :path]
    )

    update_seq_sentinel(repo, store, seq)
    :ok
  end

  @impl Dust.Cache
  def write_batch(repo, store, entries) do
    rows =
      Enum.map(entries, fn {path, value, type, seq} ->
        %{
          store: store,
          path: path,
          value: Jason.encode!(value),
          type: type,
          seq: seq
        }
      end)

    max_seq =
      Enum.reduce(rows, 0, fn row, acc ->
        repo.insert_all(CacheEntry, [row],
          on_conflict: [set: [value: row.value, type: row.type, seq: row.seq]],
          conflict_target: [:store, :path]
        )
        max(acc, row.seq)
      end)

    if max_seq > 0, do: update_seq_sentinel(repo, store, max_seq)
    :ok
  end

  @impl Dust.Cache
  def delete(repo, store, path) do
    query =
      from(c in CacheEntry,
        where: c.store == ^store and c.path == ^path
      )

    repo.delete_all(query)
    :ok
  end

  @impl Dust.Cache
  def last_seq(repo, store) do
    query =
      from(c in CacheEntry,
        where: c.store == ^store and c.path == ^@seq_sentinel_path,
        select: c.seq
      )

    repo.one(query) || 0
  end

  defp update_seq_sentinel(repo, store, seq) do
    import Ecto.Query

    sentinel = %{
      store: store,
      path: @seq_sentinel_path,
      value: Jason.encode!(seq),
      type: "integer",
      seq: seq
    }

    # Try insert; on conflict only update if new seq is higher
    repo.insert_all(CacheEntry, [sentinel],
      on_conflict:
        from(c in CacheEntry,
          update: [set: [seq: ^seq, value: ^Jason.encode!(seq)]],
          where: c.seq < ^seq
        ),
      conflict_target: [:store, :path]
    )
  end
end
