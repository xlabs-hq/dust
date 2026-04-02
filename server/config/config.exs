# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dust,
  ecto_repos: [Dust.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  migration_primary_key: [name: :id, type: :binary_id, default: {:fragment, "uuidv7()"}],
  migration_foreign_key: [type: :binary_id]

config :dust, :store_data_dir, "priv/stores"

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 120_000, cleanup_interval_ms: 60_000]}

# Configure the endpoint
config :dust, DustWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DustWeb.ErrorHTML, json: DustWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Dust.PubSub,
  live_view: [signing_salt: "LwuhSsXS"]

# Configure the admin endpoint
config :dust, AdminWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Dust.PubSub,
  live_view: [signing_salt: "dust_admin_lv_salt"]

# Configure WorkOS
config :workos, WorkOS.Client,
  api_key: System.get_env("WORKOS_API_KEY"),
  client_id: System.get_env("WORKOS_CLIENT_ID")

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :dust, Dust.Mailer, adapter: Swoosh.Adapters.Local

# Configure PhoenixVite for npm-based Vite
config :phoenix_vite, PhoenixVite.Npm,
  vite: [
    args: ~w(x vite),
    cd: Path.expand("../assets", __DIR__),
    env: %{}
  ]

# Configure Inertia
config :inertia,
  endpoint: DustWeb.Endpoint,
  static_paths: ["/.vite/manifest.json"],
  ssr: false,
  raise_on_ssr_failure: true

# Configure Oban
config :dust, Oban,
  repo: Dust.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Dust.Workers.Compaction}
     ]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
