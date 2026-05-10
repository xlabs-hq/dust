defmodule DustWeb.Api.StoreApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.Stores
  alias DustWeb.Api.Refs

  action_fallback DustWeb.Api.FallbackController

  @store_ref Refs.schema("Store")
  @unauthorized Refs.unauthorized()
  @forbidden Refs.forbidden()
  @bad_request Refs.bad_request()
  @rate_limited Refs.rate_limited()

  operation :index,
    operation_id: "stores.list",
    summary: "List stores in the current organization",
    tags: ["Stores"],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             org: %{type: :string},
             stores: %{type: :array, items: @store_ref}
           },
           required: [:org, :stores],
           example: %{
             org: "acme",
             stores: [
               %{
                 id: "0192e7f8-7c00-7000-8000-000000000001",
                 name: "config",
                 full_name: "acme/config",
                 status: "active",
                 inserted_at: "2026-01-01T00:00:00Z",
                 expires_at: nil
               }
             ]
           }
         }, description: "List of stores"},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      too_many_requests: @rate_limited
    ]

  def index(conn, _params) do
    org = conn.assigns.organization
    stores = Stores.list_stores(org)

    json(conn, %{
      org: org.slug,
      stores: Enum.map(stores, &serialize_store(org, &1))
    })
  end

  operation :create,
    operation_id: "stores.create",
    summary: "Create a new store",
    description:
      "Creates a store in **the calling token's organization**, regardless of which store the token is otherwise scoped to. Requires `write` permission, which in this version grants org-management capability — see the `Authentication` section in the spec preamble.",
    tags: ["Stores"],
    request_body:
      {%{
         type: :object,
         properties: %{
           name: %{
             type: :string,
             description: "Store name. Cannot contain `/`."
           },
           ttl: %{
             type: :integer,
             description: "Optional TTL in seconds. Store auto-expires after this duration."
           }
         },
         required: [:name],
         example: %{name: "config"}
       }, description: "Store creation payload"},
    responses: [
      created: {@store_ref, description: "Store created"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      payment_required:
        {%{
           type: :object,
           properties: %{
             error: %{type: :string, enum: ["limit_exceeded"]},
             limit: %{type: :integer},
             current: %{type: :integer}
           },
           required: [:error]
         }, description: "Plan limit exceeded"},
      unprocessable_entity:
        {Refs.schema("ValidationError"), description: "Validation error"},
      too_many_requests: @rate_limited
    ]

  def create(conn, %{"name" => name} = params) do
    org = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_write_permission(store_token) do
      handle_create(conn, org, name, params)
    end
  end

  def create(_conn, _params) do
    {:error, {:invalid_params, "name is required"}}
  end

  defp handle_create(conn, org, name, params) do
    attrs = %{name: name}
    attrs = if params["ttl"], do: Map.put(attrs, :ttl, params["ttl"]), else: attrs

    case Stores.create_store(org, attrs) do
      {:ok, store} ->
        conn
        |> put_status(201)
        |> json(serialize_store(org, store))

      {:error, :limit_exceeded, info} ->
        conn
        |> put_status(402)
        |> json(%{error: "limit_exceeded"} |> Map.merge(info))

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: format_errors(changeset)})
    end
  end

  defp serialize_store(org, store) do
    %{
      id: store.id,
      name: store.name,
      full_name: "#{org.slug}/#{store.name}",
      status: store.status,
      inserted_at: store.inserted_at,
      expires_at: store.expires_at
    }
  end

  defp verify_write_permission(store_token) do
    if Stores.StoreToken.can_write?(store_token), do: :ok, else: {:error, :forbidden}
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
