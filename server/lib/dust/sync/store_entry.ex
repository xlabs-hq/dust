defmodule Dust.Sync.StoreEntry do
  use Ecto.Schema

  @primary_key false
  schema "store_entries" do
    field :store_id, :binary_id, primary_key: true
    field :path, :string, primary_key: true
    field :value, :map
    field :type, :string, default: "map"
    field :seq, :integer

    timestamps()
  end
end
