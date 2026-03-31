defmodule DustWeb.Router do
  use DustWeb, :router

  import DustWeb.Plugs.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DustWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Shares Inertia props after all scope plugs have run
  pipeline :inertia do
    plug DustWeb.Plugs.InertiaShare
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public auth routes
  scope "/auth", DustWeb do
    pipe_through [:browser, :inertia]

    get "/login", WorkOSAuthController, :login
    get "/authorize", WorkOSAuthController, :authorize
    get "/callback", WorkOSAuthController, :callback
    delete "/logout", WorkOSAuthController, :logout
  end

  # Protected routes scoped to an organization
  scope "/:org", DustWeb do
    pipe_through [:browser, :require_authenticated_user, :assign_org_to_scope, :inertia]

    get "/", DashboardController, :index
    resources "/stores", StoreController, only: [:index, :show, :new, :create], param: "name"
    resources "/tokens", TokenController, only: [:index, :new, :create, :delete]
    get "/settings", SettingsController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dust, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DustWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
