defmodule Dust.Stores.Store do
  use Dust.Schema

  schema "stores" do
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active

    belongs_to :organization, Dust.Accounts.Organization

    has_many :store_tokens, Dust.Stores.StoreToken

    timestamps()
  end

  def changeset(store, attrs) do
    store
    |> Ecto.Changeset.cast(attrs, [:name, :status, :organization_id])
    |> Ecto.Changeset.validate_required([:name, :organization_id])
    |> Ecto.Changeset.unique_constraint([:organization_id, :name])
    |> Ecto.Changeset.validate_format(:name, ~r/^[a-z0-9][a-z0-9._-]*$/)
  end
end
