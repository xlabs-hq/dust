defmodule Dust.Repo.Migrations.CreateStoreSnapshots do
  use Ecto.Migration

  def change do
    create table(:store_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :snapshot_seq, :bigint, null: false
      add :snapshot_data, :map, null: false
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:store_snapshots, [:store_id, :snapshot_seq])

    execute(
      "ALTER TABLE store_snapshots ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE store_snapshots ALTER COLUMN id DROP DEFAULT"
    )
  end
end
