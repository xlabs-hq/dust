defmodule Dust.Repo.Migrations.CreateBlobs do
  use Ecto.Migration

  def change do
    create table(:blobs, primary_key: false) do
      add :hash, :string, primary_key: true
      add :size, :bigint, null: false
      add :content_type, :string
      add :filename, :string
      add :reference_count, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end
  end
end
