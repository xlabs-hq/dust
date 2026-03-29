defmodule AdminWeb.DashboardLive do
  use AdminWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Dashboard")}
  end

  def render(assigns) do
    ~H"""
    <h1>Dust Admin</h1>
    <p>Server is running.</p>
    """
  end
end
