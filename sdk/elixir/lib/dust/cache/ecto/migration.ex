if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Dust.Cache.Ecto.Migration do
    use Ecto.Migration

    def up do
      create table(:dust_cache, primary_key: false) do
        add(:store, :string, null: false)
        add(:path, :string, null: false)
        add(:value, :text, null: false)
        add(:type, :string, null: false)
        add(:seq, :bigint, null: false)
        # Local wall-clock (unix epoch ms) when this mirror last wrote the
        # row from a sync event. Nullable so pre-existing rows read back nil.
        add(:synced_at, :bigint, null: true)
      end

      create(unique_index(:dust_cache, [:store, :path]))
    end

    def down do
      drop(table(:dust_cache))
    end
  end
end
