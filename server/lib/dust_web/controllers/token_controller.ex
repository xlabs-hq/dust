defmodule DustWeb.TokenController do
  use DustWeb, :controller

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    tokens = Dust.Stores.list_org_tokens(scope.organization)
    stores = Dust.Stores.list_stores(scope.organization)

    conn
    |> assign(:page_title, "Tokens")
    |> render_inertia("Tokens/Index", %{
      tokens: serialize_tokens(tokens),
      stores: serialize_store_options(stores)
    })
  end

  def new(conn, _params) do
    scope = conn.assigns.current_scope
    stores = Dust.Stores.list_stores(scope.organization)

    conn
    |> assign(:page_title, "Create Token")
    |> render_inertia("Tokens/Create", %{
      stores: serialize_store_options(stores)
    })
  end

  def create(conn, params) do
    scope = conn.assigns.current_scope
    store = Dust.Stores.get_store_by_org_and_name!(scope.organization, params["store_name"])

    attrs = %{
      name: params["name"],
      read: params["read"] == "true" || params["read"] == true,
      write: params["write"] == "true" || params["write"] == true,
      created_by_id: scope.user.id
    }

    case Dust.Stores.create_store_token(store, attrs) do
      {:ok, token} ->
        stores = Dust.Stores.list_stores(scope.organization)

        conn
        |> assign(:page_title, "Token Created")
        |> render_inertia("Tokens/Created", %{
          raw_token: token.raw_token,
          token: serialize_created_token(token, store),
          stores: serialize_store_options(stores)
        })

      {:error, changeset} ->
        stores = Dust.Stores.list_stores(scope.organization)

        conn
        |> assign(:page_title, "Create Token")
        |> render_inertia("Tokens/Create", %{
          stores: serialize_store_options(stores),
          errors: format_errors(changeset)
        })
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    # Verify the token belongs to this org by checking its store
    token = Dust.Stores.get_token!(id)
    token = Dust.Repo.preload(token, :store)

    if token.store.organization_id == scope.organization.id do
      Dust.Stores.revoke_token(id)

      conn
      |> put_flash(:info, "Token revoked")
      |> redirect(to: ~p"/#{scope.organization.slug}/tokens")
    else
      conn
      |> put_flash(:error, "Token not found")
      |> redirect(to: ~p"/#{scope.organization.slug}/tokens")
    end
  end

  # Serialization

  defp serialize_tokens(tokens) do
    Enum.map(tokens, fn token ->
      %{
        id: token.id,
        name: token.name,
        store_name: token.store.name,
        permissions: %{
          read: Dust.Stores.StoreToken.can_read?(token),
          write: Dust.Stores.StoreToken.can_write?(token)
        },
        inserted_at: token.inserted_at,
        last_used_at: token.last_used_at
      }
    end)
  end

  defp serialize_created_token(token, store) do
    %{
      id: token.id,
      name: token.name,
      store_name: store.name,
      permissions: %{
        read: Dust.Stores.StoreToken.can_read?(token),
        write: Dust.Stores.StoreToken.can_write?(token)
      }
    }
  end

  defp serialize_store_options(stores) do
    Enum.map(stores, fn store ->
      %{id: store.id, name: store.name}
    end)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
