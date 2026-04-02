defmodule DustWeb.Api.TokenApiController do
  use DustWeb, :controller

  alias Dust.Stores

  def index(conn, _params) do
    org = conn.assigns.organization
    tokens = Stores.list_org_tokens(org)

    json(conn, %{
      tokens:
        Enum.map(tokens, fn token ->
          %{
            id: token.id,
            name: token.name,
            store_name: token.store.name,
            permissions: %{
              read: Stores.StoreToken.can_read?(token),
              write: Stores.StoreToken.can_write?(token)
            },
            expires_at: token.expires_at,
            last_used_at: token.last_used_at,
            inserted_at: token.inserted_at
          }
        end)
    })
  end

  def create(conn, %{"store_name" => store_name, "name" => name} = params) do
    org = conn.assigns.organization
    store_token = conn.assigns.store_token

    if not Stores.StoreToken.can_write?(store_token) do
      conn |> put_status(403) |> json(%{error: "forbidden"})
    else
      create_token(conn, org, store_token, store_name, name, params)
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "store_name and name are required"})
  end

  defp create_token(conn, org, store_token, store_name, name, params) do
    case Stores.get_store_by_name(org, store_name) do
      nil ->
        conn |> put_status(404) |> json(%{error: "store not found"})

      store ->
        attrs = %{
          name: name,
          read: params["read"] != false,
          write: params["write"] == true,
          created_by_id: store_token.created_by_id
        }

        case Stores.create_store_token(store, attrs) do
          {:ok, token} ->
            conn
            |> put_status(201)
            |> json(%{
              id: token.id,
              name: token.name,
              raw_token: token.raw_token,
              store_name: store_name,
              permissions: %{
                read: Stores.StoreToken.can_read?(token),
                write: Stores.StoreToken.can_write?(token)
              }
            })

          {:error, changeset} ->
            conn
            |> put_status(422)
            |> json(%{error: format_errors(changeset)})
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    store_token = conn.assigns.store_token
    org = conn.assigns.organization

    if not Stores.StoreToken.can_write?(store_token) do
      conn |> put_status(403) |> json(%{error: "forbidden"})
    else
      case Stores.revoke_token_in_org(id, org) do
        {:ok, _} ->
          json(conn, %{ok: true})

        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{error: "token not found"})
      end
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
