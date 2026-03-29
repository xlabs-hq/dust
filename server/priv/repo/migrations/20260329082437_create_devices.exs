defmodule Dust.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_id, :string, null: false
      add :name, :string
      add :last_seen_at, :utc_datetime_usec
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:devices, [:device_id])
    create index(:devices, [:user_id])

    execute(
      "ALTER TABLE devices ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE devices ALTER COLUMN id DROP DEFAULT"
    )
  end
end
