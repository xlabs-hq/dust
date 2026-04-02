defmodule Dust.Repo.Migrations.AddCachedMetadataToStores do
  use Ecto.Migration

  def change do
    alter table(:stores) do
      add :entry_count, :integer, null: false, default: 0
      add :op_count, :integer, null: false, default: 0
      add :current_seq, :bigint, null: false, default: 0
      add :file_storage_bytes, :bigint, null: false, default: 0
    end
  end
end
