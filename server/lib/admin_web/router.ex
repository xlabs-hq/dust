defmodule AdminWeb.Router do
  use AdminWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AdminWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", AdminWeb do
    pipe_through :browser

    live "/", OrgsLive, :index
    live "/orgs", OrgsLive, :index
    live "/orgs/:id", OrgDetailLive, :show
    live "/users", UsersLive, :index
    live "/users/:id", UserDetailLive, :show
    live "/stores", StoresLive, :index
    live "/stores/:id", StoreDetailLive, :show
    live "/ops", OpsLive, :index
  end
end
