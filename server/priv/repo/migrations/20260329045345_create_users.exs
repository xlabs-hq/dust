defmodule Dust.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :workos_id, :string
      add :first_name, :string
      add :last_name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:workos_id])

    execute(
      "ALTER TABLE users ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE users ALTER COLUMN id DROP DEFAULT"
    )
  end
end
