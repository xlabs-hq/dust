defmodule Dust.Sync.Audit do
  @moduledoc "Rich filtering and pagination for store operations (audit log)."

  import Ecto.Query
  alias Dust.Repo
  alias Dust.Sync.StoreOp

  @doc """
  Query ops for a store with optional filters.

  Options:
    - `:path`      — exact path or wildcard pattern (e.g. "users.*")
    - `:device_id` — filter by device
    - `:op`        — filter by op type (string or atom, e.g. "set" or :set)
    - `:since`     — DateTime; only ops inserted at or after this time
    - `:limit`     — max results (default 50)
    - `:offset`    — pagination offset (default 0)
  """
  def query_ops(store_id, opts \\ []) do
    from(o in StoreOp,
      where: o.store_id == ^store_id,
      order_by: [desc: o.store_seq]
    )
    |> maybe_filter_path(opts[:path])
    |> maybe_filter_device(opts[:device_id])
    |> maybe_filter_op(opts[:op])
    |> maybe_filter_since(opts[:since])
    |> limit_results(opts[:limit] || 50)
    |> offset_results(opts[:offset] || 0)
    |> Repo.all()
  end

  @doc "Count ops matching the given filters (ignores limit/offset)."
  def count_ops(store_id, opts \\ []) do
    from(o in StoreOp, where: o.store_id == ^store_id)
    |> maybe_filter_path(opts[:path])
    |> maybe_filter_device(opts[:device_id])
    |> maybe_filter_op(opts[:op])
    |> maybe_filter_since(opts[:since])
    |> select([o], count(o.id))
    |> Repo.one()
  end

  # --- filter helpers ---

  defp maybe_filter_path(query, nil), do: query
  defp maybe_filter_path(query, ""), do: query

  defp maybe_filter_path(query, path) do
    if String.contains?(path, "*") do
      # Convert glob pattern to SQL LIKE pattern
      like_pattern =
        path
        |> String.replace("%", "\\%")
        |> String.replace("_", "\\_")
        |> String.replace("**", "%%DOUBLE%%")
        |> String.replace("*", "%")
        |> String.replace("%%DOUBLE%%", "%")

      where(query, [o], like(o.path, ^like_pattern))
    else
      where(query, [o], o.path == ^path)
    end
  end

  defp maybe_filter_device(query, nil), do: query
  defp maybe_filter_device(query, ""), do: query
  defp maybe_filter_device(query, device_id), do: where(query, [o], o.device_id == ^device_id)

  defp maybe_filter_op(query, nil), do: query
  defp maybe_filter_op(query, ""), do: query

  defp maybe_filter_op(query, op) when is_atom(op), do: where(query, [o], o.op == ^op)

  defp maybe_filter_op(query, op) when is_binary(op) do
    where(query, [o], o.op == ^String.to_existing_atom(op))
  end

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, %DateTime{} = since) do
    where(query, [o], o.inserted_at >= ^since)
  end

  defp maybe_filter_since(query, since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> where(query, [o], o.inserted_at >= ^dt)
      _ -> query
    end
  end

  defp limit_results(query, limit), do: limit(query, ^limit)
  defp offset_results(query, 0), do: query
  defp offset_results(query, offset), do: offset(query, ^offset)
end
