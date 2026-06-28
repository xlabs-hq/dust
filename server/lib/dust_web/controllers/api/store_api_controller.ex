defmodule DustWeb.Api.StoreApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.AccessTokens
  alias Dust.Stores
  alias DustWeb.Api.Refs
  alias DustWeb.ApiPrincipal

  action_fallback DustWeb.Api.FallbackController

  @store_ref Refs.schema("Store")
  @unauthorized Refs.unauthorized()
  @forbidden Refs.forbidden()
  @rate_limited Refs.rate_limited()

  operation(:index,
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
  )

  def index(conn, _params) do
    principal = conn.assigns.api_principal
    org = ApiPrincipal.organization(principal)

    with :ok <- authorize_org(principal, org, "stores:read") do
      stores = stores_for(principal, org)

      json(conn, %{
        org: org.slug,
        stores: Enum.map(stores, &serialize_store(org, &1))
      })
    end
  end

  operation(:create,
    operation_id: "stores.create",
    summary: "Disabled — create stores via the dashboard",
    description: """
    Always returns `403`. Store-scoped API tokens have no authority
    to create new stores; until org-admin tokens ship, store
    creation is dashboard-only.

    The endpoint stays in the spec so the contract is explicit
    rather than silently 404. When org-admin tokens land, the
    success/limit/validation response paths will return.
    """,
    tags: ["Stores"],
    deprecated: true,
    responses: [
      unauthorized: @unauthorized,
      forbidden:
        {%{
           type: :object,
           properties: %{error: %{type: :string, enum: ["forbidden"]}},
           required: [:error],
           example: %{error: "forbidden"}
         }, description: "Always returned in v0.1"},
      too_many_requests: @rate_limited
    ]
  )

  def create(conn, %{"name" => name}) do
    principal = conn.assigns.api_principal
    org = ApiPrincipal.organization(principal)

    with :ok <- authorize_org(principal, org, "stores:create") do
      case Stores.create_store(org, %{name: name}) do
        {:ok, store} ->
          conn
          |> put_status(201)
          |> json(%{store: serialize_store(org, store)})

        {:error, :limit_exceeded, info} ->
          conn |> put_status(402) |> json(%{error: "limit_exceeded"} |> Map.merge(info))

        {:error, %Ecto.Changeset{}} ->
          conn |> put_status(422) |> json(%{error: "invalid_store"})
      end
    end
  end

  def create(_conn, _params) do
    {:error, {:invalid_params, "name is required"}}
  end

  defp stores_for(%ApiPrincipal{type: :bearer, store_token: token}, _org) do
    AccessTokens.list_accessible_stores(token)
  end

  defp stores_for(%ApiPrincipal{type: :session}, org), do: Stores.list_stores(org)

  defp authorize_org(%ApiPrincipal{type: :bearer, store_token: token}, org, scope) do
    case AccessTokens.authorize_org(token, org, scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp authorize_org(%ApiPrincipal{type: :session}, _org, _scope), do: :ok

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
