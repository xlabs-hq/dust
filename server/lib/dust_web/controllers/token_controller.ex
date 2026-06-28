defmodule DustWeb.TokenController do
  use DustWeb, :controller

  alias Dust.AccessTokens
  alias Dust.Stores

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    tokens = AccessTokens.list_org_tokens(scope.organization)
    stores = Stores.list_stores(scope.organization)

    conn
    |> assign(:page_title, "Tokens")
    |> render_inertia("Tokens/Index", %{
      tokens: serialize_tokens(tokens),
      stores: serialize_store_options(stores)
    })
  end

  def new(conn, _params) do
    scope = conn.assigns.current_scope
    stores = Stores.list_stores(scope.organization)

    conn
    |> assign(:page_title, "Create Token")
    |> render_inertia("Tokens/Create", %{
      stores: serialize_store_options(stores),
      scope_definitions: AccessTokens.scope_definitions()
    })
  end

  def create(conn, params) do
    scope = conn.assigns.current_scope

    attrs = %{
      name: params["name"],
      scopes: scopes_from_params(params),
      store_access_mode: params["store_access_mode"] || "selected",
      store_ids: store_ids_from_params(params, scope.organization),
      created_by_id: scope.user.id
    }

    case AccessTokens.create_token(scope.organization, attrs) do
      {:ok, token} ->
        stores = Stores.list_stores(scope.organization)

        conn
        |> assign(:page_title, "Token Created")
        |> render_inertia("Tokens/Created", %{
          raw_token: token.raw_token,
          token: serialize_created_token(token),
          stores: serialize_store_options(stores)
        })

      {:error, changeset} ->
        stores = Stores.list_stores(scope.organization)

        conn
        |> assign(:page_title, "Create Token")
        |> render_inertia("Tokens/Create", %{
          stores: serialize_store_options(stores),
          scope_definitions: AccessTokens.scope_definitions(),
          form: form_from_params(params, scope.organization),
          errors: format_errors(changeset)
        })
    end
  end

  def edit(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    stores = Stores.list_stores(scope.organization)

    case AccessTokens.get_token_in_org(id, scope.organization) do
      nil ->
        conn
        |> put_flash(:error, "Token not found")
        |> redirect(to: ~p"/#{scope.organization.slug}/tokens")

      token ->
        conn
        |> assign(:page_title, "Edit Token")
        |> render_inertia("Tokens/Edit", %{
          token: serialize_token_for_edit(token),
          stores: serialize_store_options(stores),
          scope_definitions: AccessTokens.scope_definitions()
        })
    end
  end

  def update(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    stores = Stores.list_stores(scope.organization)

    case AccessTokens.get_token_in_org(id, scope.organization) do
      nil ->
        conn
        |> put_flash(:error, "Token not found")
        |> redirect(to: ~p"/#{scope.organization.slug}/tokens")

      token ->
        attrs = %{
          name: params["name"],
          scopes: scopes_from_params(params),
          store_access_mode: params["store_access_mode"] || "selected",
          store_ids: store_ids_from_params(params, scope.organization)
        }

        case AccessTokens.update_token(token, scope.organization, attrs) do
          {:ok, _token} ->
            conn
            |> put_flash(:info, "Token updated")
            |> redirect(to: ~p"/#{scope.organization.slug}/tokens")

          {:error, changeset} ->
            conn
            |> assign(:page_title, "Edit Token")
            |> render_inertia("Tokens/Edit", %{
              token:
                Map.merge(
                  serialize_token_for_edit(token),
                  form_from_params(params, scope.organization)
                ),
              stores: serialize_store_options(stores),
              scope_definitions: AccessTokens.scope_definitions(),
              errors: format_errors(changeset)
            })
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case AccessTokens.revoke_token_in_org(id, scope.organization, scope.user.id) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Token revoked")
        |> redirect(to: ~p"/#{scope.organization.slug}/tokens")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Token not found")
        |> redirect(to: ~p"/#{scope.organization.slug}/tokens")
    end
  end

  defp scopes_from_params(%{"scopes" => scopes}) when is_list(scopes), do: scopes

  defp scopes_from_params(params) do
    AccessTokens.legacy_scopes(
      truthy?(params["read"]),
      truthy?(params["write"])
    )
  end

  defp store_ids_from_params(%{"store_access_mode" => "all"}, _organization), do: []

  defp store_ids_from_params(%{"store_ids" => store_ids}, _organization) when is_list(store_ids),
    do: store_ids

  defp store_ids_from_params(%{"store_id" => store_id}, _organization) when is_binary(store_id),
    do: [store_id]

  defp store_ids_from_params(%{"store_name" => store_name}, organization)
       when is_binary(store_name) do
    case Stores.get_store_by_name(organization, store_name) do
      nil -> []
      store -> [store.id]
    end
  end

  defp store_ids_from_params(_params, _organization), do: []

  defp form_from_params(params, organization) do
    %{
      name: params["name"] || "",
      scopes: scopes_from_params(params),
      store_access_mode: params["store_access_mode"] || "selected",
      store_ids: store_ids_from_params(params, organization)
    }
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]

  defp serialize_tokens(tokens), do: Enum.map(tokens, &serialize_token/1)

  defp serialize_token(token) do
    %{
      id: token.id,
      name: token.name,
      store_label: store_label(token),
      store_access_mode: token.store_access_mode,
      stores: serialize_token_stores(token),
      scopes: token.scopes,
      permissions: serialize_permissions(token),
      inserted_at: token.inserted_at,
      last_used_at: token.last_used_at
    }
  end

  defp serialize_token_for_edit(token) do
    %{
      id: token.id,
      name: token.name,
      store_access_mode: token.store_access_mode,
      store_ids: token.store_ids,
      scopes: token.scopes
    }
  end

  defp serialize_created_token(token) do
    %{
      id: token.id,
      name: token.name,
      store_label: store_label(token),
      store_access_mode: token.store_access_mode,
      stores: serialize_token_stores(token),
      scopes: token.scopes,
      permissions: serialize_permissions(token)
    }
  end

  defp store_label(%{store_access_mode: :all}), do: "All stores"

  defp store_label(token) do
    case serialize_token_stores(token) do
      [] -> "No stores"
      [store] -> store.name
      stores -> "#{length(stores)} stores"
    end
  end

  defp serialize_token_stores(%{store_access_mode: :all}), do: []

  defp serialize_token_stores(token) do
    Enum.map(token.store_grants, fn grant ->
      %{id: grant.store.id, name: grant.store.name}
    end)
  end

  defp serialize_permissions(token) do
    %{
      read: AccessTokens.has_scope?(token, "entries:read"),
      write: AccessTokens.has_scope?(token, "entries:write")
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
