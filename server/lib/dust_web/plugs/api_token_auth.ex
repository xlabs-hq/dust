defmodule DustWeb.Plugs.ApiTokenAuth do
  @moduledoc """
  Authenticates API requests via either:

    * a bearer token in the `Authorization` header (machines, SDK, CLI), or
    * the web session cookie (the logged-in user's browser).

  On success, assigns a `%DustWeb.ApiPrincipal{}` at
  `:api_principal`. Downstream code reads that — never the raw
  bearer-token assign — so the controller doesn't care which path got
  us here. The legacy `:store_token` and `:organization` assigns are
  also set when a bearer token is used so existing code that still
  reads them keeps working.
  """
  import Plug.Conn

  alias Dust.Accounts
  alias Dust.Accounts.Organization
  alias DustWeb.ApiPrincipal

  def init(opts), do: opts

  def call(conn, _opts) do
    with :no_bearer <- try_bearer(conn),
         :no_session <- try_session(conn) do
      unauthorized(conn)
    else
      {:ok, conn} -> conn
    end
  end

  defp try_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw_token] ->
        case Dust.Stores.authenticate_token(raw_token) do
          {:ok, store_token} ->
            principal = ApiPrincipal.from_bearer(store_token)

            {:ok,
             conn
             |> assign(:api_principal, principal)
             |> assign(:store_token, store_token)
             |> assign(:organization, store_token.organization)}

          _ ->
            :no_bearer
        end

      _ ->
        :no_bearer
    end
  end

  # Session auth requires three things: a logged-in user on
  # `current_scope`, an `:org` path param, and confirmed membership of
  # that org. The membership query is one extra SELECT per request;
  # cheap and avoids trusting the preloaded organizations list past
  # the first request after login.
  defp try_session(conn) do
    scope = conn.assigns[:current_scope]
    org_slug = conn.params["org"]

    cond do
      is_nil(scope) or is_nil(scope.user) ->
        :no_session

      is_nil(org_slug) or org_slug == "" ->
        :no_session

      true ->
        case find_org_for_user(scope.user, org_slug) do
          {:ok, org} ->
            principal = ApiPrincipal.from_session(scope.user, org)
            {:ok, assign(conn, :api_principal, principal)}

          :not_a_member ->
            :no_session
        end
    end
  end

  defp find_org_for_user(user, org_slug) do
    case Enum.find(user.organizations || [], &(&1.slug == org_slug)) do
      nil ->
        # Fall back to a DB lookup: the preloaded list might be stale,
        # or the user might have joined an org since session start.
        case Dust.Repo.get_by(Organization, slug: org_slug) do
          nil ->
            :not_a_member

          org ->
            case Accounts.get_organization_membership(user, org) do
              nil -> :not_a_member
              _membership -> {:ok, org}
            end
        end

      org ->
        {:ok, org}
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: "unauthorized"})
    |> halt()
  end
end
