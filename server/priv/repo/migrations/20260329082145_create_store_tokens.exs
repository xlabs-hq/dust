defmodule Dust.Repo.Migrations.CreateStoreTokens do
  use Ecto.Migration

  def change do
    create table(:store_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :permissions, :integer, null: false, default: 1
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:store_tokens, [:store_id])
    create unique_index(:store_tokens, [:token_hash])

    execute(
      "ALTER TABLE store_tokens ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE store_tokens ALTER COLUMN id DROP DEFAULT"
    )
  end
end
