defmodule DustWeb.Plugs.Auth do
  @moduledoc """
  Authentication plugs for the Dust web application.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Dust.Accounts
  alias Dust.Accounts.Scope

  use DustWeb, :verified_routes

  @doc """
  Reads the session token, loads the user with their organizations,
  and builds a Scope struct assigned as `:current_scope`.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    if token = get_session(conn, :user_token) do
      case Accounts.get_user_by_session_token(token) do
        {user, _token_inserted_at} ->
          user = Dust.Repo.preload(user, :organizations)
          assign(conn, :current_scope, Scope.for_user(user))

        nil ->
          assign(conn, :current_scope, nil)
      end
    else
      assign(conn, :current_scope, nil)
    end
  end

  @doc """
  Requires that a user is authenticated.
  Redirects to `/auth/login` if no current scope or no user.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/auth/login")
      |> halt()
    end
  end

  @doc """
  Resolves the organization from the `:org` URL param and adds it to the scope.
  Checks that the user is actually a member of the organization.
  """
  def assign_org_to_scope(conn, _opts) do
    scope = conn.assigns[:current_scope]
    slug = conn.params["org"]

    if scope && scope.user && slug do
      case Enum.find(scope.user.organizations, &(&1.slug == slug)) do
        nil ->
          conn
          |> put_flash(:error, "Organization not found or you don't have access.")
          |> redirect(to: ~p"/auth/login")
          |> halt()

        org ->
          # Store as last-used org
          conn
          |> put_session(:last_org_slug, org.slug)
          |> assign(:current_scope, Scope.put_organization(scope, org))
      end
    else
      conn
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
