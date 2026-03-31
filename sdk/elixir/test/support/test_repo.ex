defmodule Dust.TestRepo do
  use Ecto.Repo, otp_app: :dust, adapter: Ecto.Adapters.SQLite3
end
