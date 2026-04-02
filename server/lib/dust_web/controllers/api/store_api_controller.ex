defmodule DustWeb.Api.StoreApiController do
  use DustWeb, :controller

  alias Dust.Stores

  def index(conn, _params) do
    org = conn.assigns.organization
    stores = Stores.list_stores(org)

    json(conn, %{
      stores:
        Enum.map(stores, fn store ->
          %{
            id: store.id,
            name: store.name,
            full_name: "#{org.slug}/#{store.name}",
            status: store.status,
            inserted_at: store.inserted_at
          }
        end)
    })
  end

  def create(conn, %{"name" => name}) do
    org = conn.assigns.organization
    store_token = conn.assigns.store_token

    if not Stores.StoreToken.can_write?(store_token) do
      conn |> put_status(403) |> json(%{error: "forbidden"})
    else
      case Stores.create_store(org, %{name: name}) do
        {:ok, store} ->
          conn
          |> put_status(201)
          |> json(%{
            id: store.id,
            name: store.name,
            full_name: "#{org.slug}/#{store.name}",
            status: store.status
          })

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
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "name is required"})
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
