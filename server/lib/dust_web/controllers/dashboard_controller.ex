defmodule DustWeb.DashboardController do
  use DustWeb, :controller

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    stats = Dust.Stores.get_org_stats(scope.organization)

    conn
    |> assign(:page_title, "Dashboard")
    |> render_inertia("Dashboard/Index", %{
      stats: stats
    })
  end
end
