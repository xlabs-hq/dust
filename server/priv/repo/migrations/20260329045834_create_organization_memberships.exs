defmodule Dust.Repo.Migrations.CreateOrganizationMemberships do
  use Ecto.Migration

  def change do
    create table(:organization_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "member"
      add :deleted_at, :utc_datetime_usec
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:organization_memberships, [:user_id])
    create index(:organization_memberships, [:organization_id])
    create unique_index(:organization_memberships, [:user_id, :organization_id],
      where: "deleted_at IS NULL", name: :org_memberships_user_org_active)

    execute(
      "ALTER TABLE organization_memberships ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE organization_memberships ALTER COLUMN id DROP DEFAULT"
    )
  end
end
