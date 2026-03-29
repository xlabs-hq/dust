defmodule Dust.Repo.Migrations.CreateStoreEntries do
  use Ecto.Migration

  def change do
    create table(:store_entries, primary_key: false) do
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :value, :map
      add :type, :string, null: false, default: "map"
      add :seq, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE store_entries ADD PRIMARY KEY (store_id, path)",
      "ALTER TABLE store_entries DROP CONSTRAINT store_entries_pkey"
    )
  end
end
