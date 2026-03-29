defmodule DustWeb.PageController do
  use DustWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
