defmodule Dust.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :workos_organization_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organizations, [:slug])
    create unique_index(:organizations, [:workos_organization_id])

    execute(
      "ALTER TABLE organizations ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE organizations ALTER COLUMN id DROP DEFAULT"
    )
  end
end
