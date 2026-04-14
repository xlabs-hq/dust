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

  # JSON endpoints that need session/CSRF (auth forms)
  pipeline :browser_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug DustWeb.Plugs.MCPAuth
  end

  pipeline :mcp_oauth do
    plug :accepts, ["json", "html"]
    plug :fetch_session
  end

  # Public landing page
  scope "/", DustWeb do
    pipe_through [:browser, :inertia]
    get "/", LandingController, :index
  end

  # Public auth pages (HTML/Inertia)
  scope "/auth", DustWeb do
    pipe_through [:browser, :inertia]

    get "/login", WorkOSAuthController, :login
    get "/register", WorkOSAuthController, :register
    get "/forgot-password", WorkOSAuthController, :forgot_password
    get "/reset-password", WorkOSAuthController, :reset_password_page
    get "/authorize", WorkOSAuthController, :authorize
    get "/callback", WorkOSAuthController, :callback
    delete "/logout", WorkOSAuthController, :logout
  end

  # Auth form submissions (JSON)
  scope "/auth", DustWeb do
    pipe_through [:browser_api]

    post "/check-email", WorkOSAuthController, :check_email
    post "/sign-in", WorkOSAuthController, :sign_in
    post "/sign-up", WorkOSAuthController, :sign_up
    post "/verify-email", WorkOSAuthController, :verify_email
    post "/resend-verification", WorkOSAuthController, :resend_verification
    post "/forgot-password", WorkOSAuthController, :send_reset_email
    post "/reset-password", WorkOSAuthController, :do_reset_password
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

    get "/stores/:org/:store/log", AuditApiController, :index

    get "/stores/:org/:store/entries", EntriesApiController, :index
    post "/stores/:org/:store/entries/batch", EntriesApiController, :batch
    put "/stores/:org/:store/entries/*path", EntriesApiController, :put
    get "/stores/:org/:store/entries/*path", EntriesApiController, :show

    get "/stores/:org/:store/webhooks", WebhookController, :index
    post "/stores/:org/:store/webhooks", WebhookController, :create
    delete "/stores/:org/:store/webhooks/:id", WebhookController, :delete
    post "/stores/:org/:store/webhooks/:id/ping", WebhookController, :ping
    get "/stores/:org/:store/webhooks/:id/deliveries", WebhookController, :deliveries
  end

  # MCP OAuth discovery + DCR endpoints (unauthenticated)
  # Must be above /:org to prevent that catch-all from matching well-known URLs
  scope "/", DustWeb do
    pipe_through :mcp_oauth

    get "/.well-known/oauth-protected-resource", MCPAuthController, :oauth_protected_resource
    get "/.well-known/oauth-authorization-server", MCPAuthController, :oauth_authorization_server
    post "/register", MCPAuthController, :register
    get "/oauth/authorize", MCPAuthController, :oauth_authorize
    get "/oauth/callback", MCPAuthController, :oauth_callback
    post "/oauth/token", MCPAuthController, :oauth_token
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
      copy_assigns: [:mcp_principal, :store_token],
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
        Dust.MCP.Tools.DustRollback,
        Dust.MCP.Tools.DustPutFile,
        Dust.MCP.Tools.DustFetchFile,
        Dust.MCP.Tools.DustCreateStore,
        Dust.MCP.Tools.DustExport,
        Dust.MCP.Tools.DustDiff,
        Dust.MCP.Tools.DustImport,
        Dust.MCP.Tools.DustClone
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
