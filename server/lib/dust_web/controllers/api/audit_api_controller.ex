defmodule DustWeb.Api.AuditApiController do
  use DustWeb, :controller

  alias Dust.{Stores, Sync.Audit}

  def index(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_read_permission(store_token) do
      filters = parse_filters(params)
      limit = parse_int(params["limit"], 50)
      page = parse_int(params["page"], 1)
      offset = (page - 1) * limit

      opts = [limit: limit, offset: offset] ++ filters

      ops = Audit.query_ops(store.id, opts)
      total = Audit.count_ops(store.id, filters)
      total_pages = max(1, ceil(total / limit))

      json(conn, %{
        ops: serialize_ops(ops),
        pagination: %{
          page: page,
          limit: limit,
          total: total,
          total_pages: total_pages
        }
      })
    else
      {:error, :org_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})
    end
  end

  defp verify_org(organization, org_slug) do
    if organization.slug == org_slug, do: :ok, else: {:error, :org_mismatch}
  end

  defp find_store(organization, store_name) do
    case Stores.get_store_by_name(organization, store_name) do
      nil -> {:error, :not_found}
      store -> {:ok, store}
    end
  end

  defp verify_token_scope(store_token, store) do
    if store_token.store_id == store.id, do: :ok, else: {:error, :forbidden}
  end

  defp verify_read_permission(store_token) do
    if Stores.StoreToken.can_read?(store_token), do: :ok, else: {:error, :forbidden}
  end

  defp parse_filters(params) do
    []
    |> maybe_add(:path, params["path"])
    |> maybe_add(:device_id, params["device_id"])
    |> maybe_add(:op, params["op"])
    |> maybe_add(:since, params["since"])
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val

  defp serialize_ops(ops) do
    Enum.map(ops, fn op ->
      %{
        store_seq: op.store_seq,
        op: op.op,
        path: op.path,
        value: op.value,
        device_id: op.device_id,
        inserted_at: op.inserted_at
      }
    end)
  end
end
