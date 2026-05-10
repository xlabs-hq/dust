defmodule DustWeb.Api.AuditApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Stores, Sync.Audit}

  action_fallback DustWeb.Api.FallbackController

  operation :index,
    summary: "List audit log entries for a store",
    tags: ["Audit"],
    parameters: [
      org: [in: :path, schema: %{type: :string}, required: true],
      store: [in: :path, schema: %{type: :string}, required: true],
      path: [in: :query, schema: %{type: :string}, required: false],
      device_id: [in: :query, schema: %{type: :string}, required: false],
      op: [in: :query, schema: %{type: :string}, required: false],
      since: [in: :query, schema: %{type: :string, format: "date-time"}, required: false],
      limit: [in: :query, schema: %{type: :integer, default: 50}, required: false],
      page: [in: :query, schema: %{type: :integer, default: 1}, required: false]
    ],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             ops: %{
               type: :array,
               items: %{
                 type: :object,
                 properties: %{
                   store_seq: %{type: :integer},
                   op: %{type: :string},
                   path: %{type: :string},
                   value: %{},
                   device_id: %{type: :string},
                   inserted_at: %{type: :string, format: "date-time"}
                 }
               }
             },
             pagination: %{
               type: :object,
               properties: %{
                 page: %{type: :integer},
                 limit: %{type: :integer},
                 total: %{type: :integer},
                 total_pages: %{type: :integer}
               }
             }
           }
         }, description: "Paginated audit log"}
    ]

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
    |> maybe_add(:path, normalize_filter_path(params["path"]))
    |> maybe_add(:device_id, params["device_id"])
    |> maybe_add(:op, params["op"])
    |> maybe_add(:since, params["since"])
  end

  defp normalize_filter_path(nil), do: nil
  defp normalize_filter_path(""), do: nil

  defp normalize_filter_path(path) when is_binary(path) do
    case DustProtocol.Path.normalize_pattern(path) do
      {:ok, normalized} -> normalized
      {:error, _} -> path
    end
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
