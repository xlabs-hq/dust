defmodule DustWeb.LandingController do
  use DustWeb, :controller

  def index(conn, _params) do
    # If user is already logged in, redirect to their org dashboard
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      org = hd(Dust.Accounts.list_user_organizations(conn.assigns.current_scope.user))
      redirect(conn, to: ~p"/#{org.slug}")
    else
      conn
      |> assign(:page_title, "Dust — Reactive Global Map")
      |> render_inertia("Landing")
    end
  end
end
