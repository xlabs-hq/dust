defmodule Dust.Repo.Migrations.CreateStores do
  use Ecto.Migration

  def change do
    create table(:stores, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stores, [:organization_id])
    create unique_index(:stores, [:organization_id, :name])

    execute(
      "ALTER TABLE stores ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE stores ALTER COLUMN id DROP DEFAULT"
    )
  end
end
