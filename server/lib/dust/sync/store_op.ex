defmodule Dust.Sync.StoreOp do
  use Dust.Schema

  schema "store_ops" do
    field :store_seq, :integer
    field :op, Ecto.Enum, values: [:set, :delete, :merge, :increment, :add, :remove, :put_file]
    field :path, :string
    field :value, :map
    field :type, :string, default: "map"
    field :device_id, :string
    field :client_op_id, :string
    field :materialized_value, :any, virtual: true

    belongs_to :store, Dust.Stores.Store

    timestamps(updated_at: false)
  end
end
