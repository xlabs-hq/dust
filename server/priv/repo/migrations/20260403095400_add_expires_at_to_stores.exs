defmodule Dust.Repo.Migrations.AddExpiresAtToStores do
  use Ecto.Migration

  def change do
    alter table(:stores) do
      add :expires_at, :utc_datetime_usec
    end
  end
end
