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
    summary: "Create a new store (deprecated for store-scoped tokens)",
    description: """
    **Not available with store-scoped tokens.** Returns `403` —
    store creation is dashboard-only in v0.1, since store-scoped
    tokens have no authority to operate outside their own store.
    Granular org-admin tokens (which will re-enable this endpoint
    over the API) are on the roadmap.

    The endpoint stays in the spec so the contract is explicit, but
    every call returns `403 forbidden` until org-admin tokens ship.
    """,
    tags: ["Stores"],
    deprecated: true,
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

  def create(_conn, _params) do
    # Store-scoped tokens have no authority to create new stores. Until
    # org-admin tokens ship, this endpoint always returns 403 — store
    # creation is dashboard-only.
    {:error, :forbidden}
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
end
