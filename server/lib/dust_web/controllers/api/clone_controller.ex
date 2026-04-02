defmodule DustWeb.Api.CloneController do
  use DustWeb, :controller

  alias Dust.{Stores, Sync}

  def create(conn, %{"org" => org_slug, "store" => store_name, "name" => target_name}) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, source} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, source),
         :ok <- verify_write_permission(store_token),
         {:ok, target} <- Sync.Clone.clone_store(source, organization, target_name) do
      conn
      |> put_status(201)
      |> json(%{ok: true, store: %{id: target.id, name: target.name, full_name: "#{org_slug}/#{target.name}"}})
    else
      {:error, :org_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :limit_exceeded, info} ->
        conn |> put_status(402) |> json(%{error: "limit_exceeded"} |> Map.merge(info))

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{error: "name_taken"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "name is required"})
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
