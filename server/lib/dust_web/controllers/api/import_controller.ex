defmodule DustWeb.Api.ImportController do
  use DustWeb, :controller

  alias Dust.{Stores, Sync}

  def create(conn, %{"org" => org_slug, "store" => store_name}) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_write_permission(store_token),
         {:ok, body, conn} <- Plug.Conn.read_body(conn) do
      lines = String.split(body, "\n")
      {:ok, count} = Sync.Import.from_jsonl(store.id, lines, "system:import")
      json(conn, %{ok: true, entries_imported: count})
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
