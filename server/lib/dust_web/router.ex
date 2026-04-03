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

  pipeline :mcp do
    plug :accepts, ["json"]
    plug DustWeb.Plugs.MCPAuth
  end

  # Public landing page
  scope "/", DustWeb do
    pipe_through [:browser, :inertia]
    get "/", LandingController, :index
  end

  # Public auth routes
  scope "/auth", DustWeb do
    pipe_through [:browser, :inertia]

    get "/login", WorkOSAuthController, :login
    get "/authorize", WorkOSAuthController, :authorize
    get "/callback", WorkOSAuthController, :callback
    delete "/logout", WorkOSAuthController, :logout
  end

  # Health check endpoints (no auth)
  scope "/", DustWeb do
    pipe_through :api
    get "/healthz", HealthController, :healthz
    get "/readyz", HealthController, :readyz
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug DustWeb.Plugs.ApiTokenAuth
  end

  # Org-scoped REST API (authenticated via Bearer token)
  # Must be above /:org to prevent that catch-all from matching /api
  scope "/api", DustWeb.Api do
    pipe_through :api_auth

    get "/stores", StoreApiController, :index
    post "/stores", StoreApiController, :create
    get "/tokens", TokenApiController, :index
    post "/tokens", TokenApiController, :create
    delete "/tokens/:id", TokenApiController, :delete
    get "/stores/:org/:store/export", ExportController, :show
    get "/stores/:org/:store/diff", DiffController, :show
    post "/stores/:org/:store/import", ImportController, :create
    post "/stores/:org/:store/clone", CloneController, :create

    get "/stores/:org/:store/webhooks", WebhookController, :index
    post "/stores/:org/:store/webhooks", WebhookController, :create
    delete "/stores/:org/:store/webhooks/:id", WebhookController, :delete
    post "/stores/:org/:store/webhooks/:id/ping", WebhookController, :ping
    get "/stores/:org/:store/webhooks/:id/deliveries", WebhookController, :deliveries
  end

  # Protected routes scoped to an organization
  scope "/:org", DustWeb do
    pipe_through [:browser, :require_authenticated_user, :assign_org_to_scope, :inertia]

    get "/", DashboardController, :index
    resources "/stores", StoreController, only: [:index, :show, :new, :create], param: "name"
    get "/stores/:name/log", AuditController, :index
    get "/stores/:name/webhooks", WebhookPageController, :index
    post "/stores/:name/webhooks", WebhookPageController, :create
    delete "/stores/:name/webhooks/:id", WebhookPageController, :delete
    resources "/tokens", TokenController, only: [:index, :new, :create, :delete]
    get "/settings", SettingsController, :index
  end

  # File download endpoint (has its own Bearer token auth inline)
  scope "/api/files", DustWeb do
    pipe_through :api
    get "/:hash", FileController, :show
  end

  # MCP endpoint for AI tool access
  scope "/mcp" do
    pipe_through :mcp

    forward "/", DustWeb.MCPTransport,
      server: GenMCP.Suite,
      server_name: "Dust",
      server_version: "0.1.0",
      copy_assigns: [:store_token],
      tools: [
        Dust.MCP.Tools.DustGet,
        Dust.MCP.Tools.DustPut,
        Dust.MCP.Tools.DustMerge,
        Dust.MCP.Tools.DustDelete,
        Dust.MCP.Tools.DustEnum,
        Dust.MCP.Tools.DustIncrement,
        Dust.MCP.Tools.DustAdd,
        Dust.MCP.Tools.DustRemove,
        Dust.MCP.Tools.DustStores,
        Dust.MCP.Tools.DustStatus,
        Dust.MCP.Tools.DustLog,
        Dust.MCP.Tools.DustPutFile,
        Dust.MCP.Tools.DustFetchFile
      ]
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
