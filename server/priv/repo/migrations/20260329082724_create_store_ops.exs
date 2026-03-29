defmodule Dust.Repo.Migrations.CreateStoreOps do
  use Ecto.Migration

  def change do
    create table(:store_ops, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :store_seq, :bigint, null: false
      add :op, :string, null: false
      add :path, :string, null: false
      add :value, :map
      add :type, :string, null: false, default: "map"
      add :device_id, :string, null: false
      add :client_op_id, :string, null: false
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:store_ops, [:store_id, :store_seq], unique: true)
    create index(:store_ops, [:store_id, :path])

    execute(
      "ALTER TABLE store_ops ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE store_ops ALTER COLUMN id DROP DEFAULT"
    )
  end
end
