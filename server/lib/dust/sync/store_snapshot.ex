defmodule Dust.Sync.StoreSnapshot do
  use Dust.Schema

  schema "store_snapshots" do
    field :snapshot_seq, :integer
    field :snapshot_data, :map

    belongs_to :store, Dust.Stores.Store

    timestamps(updated_at: false)
  end
end
