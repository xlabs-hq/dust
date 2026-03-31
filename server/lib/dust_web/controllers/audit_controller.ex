defmodule DustWeb.AuditController do
  use DustWeb, :controller

  alias Dust.Sync.Audit

  def index(conn, %{"name" => store_name} = params) do
    scope = conn.assigns.current_scope
    store = Dust.Stores.get_store_by_org_and_name!(scope.organization, store_name)

    filters = parse_filters(params)
    limit = parse_int(params["limit"], 50)
    page = parse_int(params["page"], 1)
    offset = (page - 1) * limit

    opts = [limit: limit, offset: offset] ++ filters

    ops = Audit.query_ops(store.id, opts)
    total = Audit.count_ops(store.id, filters)
    total_pages = max(1, ceil(total / limit))

    conn
    |> assign(:page_title, "Audit Log - #{store.name}")
    |> render_inertia("Stores/AuditLog", %{
      store: %{
        id: store.id,
        name: store.name,
        full_name: "#{scope.organization.slug}/#{store.name}"
      },
      ops: serialize_ops(ops),
      filters: %{
        path: params["path"] || "",
        device_id: params["device_id"] || "",
        op: params["op"] || "",
        since: params["since"] || ""
      },
      pagination: %{
        page: page,
        limit: limit,
        total: total,
        total_pages: total_pages
      }
    })
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
