defmodule Dust.Cache.Ecto do
  @behaviour Dust.Cache

  import Ecto.Query

  alias Dust.Cache.Ecto.CacheEntry

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
    compiled = DustProtocol.Glob.compile(pattern)

    query =
      from(c in CacheEntry,
        where: c.store == ^store,
        select: {c.path, c.value}
      )

    repo.all(query)
    |> Enum.filter(fn {path, _} ->
      DustProtocol.Glob.match?(compiled, String.split(path, "."))
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

    # Process one at a time to handle upsert correctly across all databases
    Enum.each(rows, fn row ->
      repo.insert_all(CacheEntry, [row],
        on_conflict: [set: [value: row.value, type: row.type, seq: row.seq]],
        conflict_target: [:store, :path]
      )
    end)

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
        where: c.store == ^store,
        select: max(c.seq)
      )

    repo.one(query) || 0
  end
end
