defmodule DustWeb.PageController do
  use DustWeb, :controller

  def home(conn, _params) do
    render_inertia(conn, "Home")
  end
end
