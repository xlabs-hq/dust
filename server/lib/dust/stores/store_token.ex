defmodule Dust.Stores.StoreToken do
  use Dust.Schema

  import Bitwise

  @read_permission 1
  @write_permission 2

  schema "store_tokens" do
    field :name, :string
    field :token_hash, :binary
    field :permissions, :integer, default: 1
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :raw_token, :string, virtual: true

    belongs_to :store, Dust.Stores.Store
    belongs_to :created_by, Dust.Accounts.User, foreign_key: :created_by_id

    timestamps()
  end

  def can_read?(%__MODULE__{permissions: p}), do: (p &&& @read_permission) != 0
  def can_write?(%__MODULE__{permissions: p}), do: (p &&& @write_permission) != 0

  def permissions_integer(read?, write?) do
    if(read?, do: @read_permission, else: 0) + if write?, do: @write_permission, else: 0
  end

  def changeset(token, attrs) do
    token
    |> Ecto.Changeset.cast(attrs, [
      :name,
      :token_hash,
      :permissions,
      :expires_at,
      :store_id,
      :created_by_id
    ])
    |> Ecto.Changeset.validate_required([:name, :token_hash, :permissions, :store_id])
    |> Ecto.Changeset.unique_constraint(:token_hash)
  end
end
