defmodule DustWeb.Api.CloneController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Stores, Sync}
  alias DustWeb.Api.Refs

  action_fallback DustWeb.Api.FallbackController

  operation :create,
    operation_id: "stores.clone",
    summary: "Clone a store into a new store",
    description:
      "Creates a new store containing a snapshot of the source store's entries. The new store starts at sequence 0 and accepts writes immediately.",
    tags: ["Stores"],
    parameters: [
      _: Refs.parameter("OrgSlug"),
      _: Refs.parameter("StoreName"),
      _: Refs.parameter("RequestId")
    ],
    request_body:
      {%{
         type: :object,
         properties: %{name: %{type: :string, description: "Target store name."}},
         required: [:name],
         example: %{name: "config-clone"}
       }, description: "Clone target"},
    responses: [
      created:
        {%{
           type: :object,
           properties: %{
             ok: %{type: :boolean},
             store: %{
               type: :object,
               properties: %{
                 id: %{type: :string, format: :uuid},
                 name: %{type: :string},
                 full_name: %{type: :string}
               },
               required: [:id, :name, :full_name]
             }
           },
           required: [:ok, :store]
         }, description: "Cloned store"},
      bad_request: Refs.bad_request(),
      unauthorized: Refs.unauthorized(),
      forbidden: Refs.forbidden(),
      not_found: Refs.not_found(),
      payment_required:
        {%{
           type: :object,
           properties: %{error: %{type: :string, enum: ["limit_exceeded"]}},
           required: [:error]
         }, description: "Plan limit exceeded"},
      unprocessable_entity:
        {%{
           type: :object,
           properties: %{error: %{type: :string, enum: ["name_taken"]}},
           required: [:error]
         }, description: "Target name already exists"},
      too_many_requests: Refs.rate_limited()
    ]

  def create(conn, %{"org" => org_slug, "store" => store_name, "name" => target_name}) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, source} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, source),
         :ok <- verify_write_permission(store_token) do
      do_clone(conn, source, organization, org_slug, target_name)
    end
  end

  def create(_conn, _params) do
    {:error, {:invalid_params, "name is required"}}
  end

  defp do_clone(conn, source, organization, org_slug, target_name) do
    case Sync.Clone.clone_store(source, organization, target_name) do
      {:ok, target} ->
        conn
        |> put_status(201)
        |> json(%{
          ok: true,
          store: %{id: target.id, name: target.name, full_name: "#{org_slug}/#{target.name}"}
        })

      {:error, :limit_exceeded, info} ->
        conn |> put_status(402) |> json(%{error: "limit_exceeded"} |> Map.merge(info))

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{error: "name_taken"})
    end
  end

  defp verify_org(organization, org_slug) do
    if organization.slug == org_slug do
      :ok
    else
      {:error, :org_mismatch}
    end
  end

  defp find_store(organization, store_name) do
    case Stores.get_store_by_name(organization, store_name) do
      nil -> {:error, :not_found}
      store -> {:ok, store}
    end
  end

  defp verify_token_scope(store_token, store) do
    if store_token.store_id == store.id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp verify_write_permission(store_token) do
    if Stores.StoreToken.can_write?(store_token) do
      :ok
    else
      {:error, :forbidden}
    end
  end
end
