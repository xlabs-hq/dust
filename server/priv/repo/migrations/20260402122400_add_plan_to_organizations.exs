defmodule Dust.Repo.Migrations.AddPlanToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :plan, :string, null: false, default: "free"
    end
  end
end
