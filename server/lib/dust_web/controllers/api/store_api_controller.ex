defmodule DustWeb.Api.StoreApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.Stores

  action_fallback DustWeb.Api.FallbackController

  @store_schema %{
    type: :object,
    properties: %{
      id: %{type: :string, format: :uuid},
      name: %{type: :string},
      full_name: %{type: :string, description: "org_slug/store_name"},
      status: %{type: :string, enum: ["active", "expired"]},
      inserted_at: %{type: :string, format: "date-time"},
      expires_at: %{type: :string, format: "date-time", nullable: true}
    }
  }

  operation :index,
    summary: "List stores in the current organization",
    tags: ["Stores"],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             org: %{type: :string},
             stores: %{type: :array, items: @store_schema}
           }
         }, description: "List of stores"}
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
    summary: "Create a new store",
    tags: ["Stores"],
    request_body:
      {%{
         type: :object,
         properties: %{
           name: %{type: :string, description: "Store name (slash-separated paths supported)"},
           ttl: %{type: :integer, description: "Optional TTL in seconds"}
         },
         required: [:name]
       }, description: "Store creation payload"},
    responses: [
      created: {@store_schema, description: "Store created"},
      payment_required:
        {%{
           type: :object,
           properties: %{error: %{type: :string, enum: ["limit_exceeded"]}}
         }, description: "Plan limit exceeded"},
      unprocessable_entity:
        {%{type: :object, properties: %{error: %{type: :object}}},
         description: "Validation error"}
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
