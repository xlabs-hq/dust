defmodule Dust.Repo do
  use Ecto.Repo,
    otp_app: :dust,
    adapter: Ecto.Adapters.Postgres
end
