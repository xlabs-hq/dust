defmodule Dust.TestRepo do
  use Ecto.Repo, otp_app: :dustlayer, adapter: Ecto.Adapters.SQLite3
end
