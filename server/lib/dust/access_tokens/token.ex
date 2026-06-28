defmodule Dust.AccessTokens.Token do
  use Dust.Schema

  alias Dust.AccessTokens.ScopeGrant
  alias Dust.AccessTokens.StoreGrant
  alias Dust.Accounts.Organization
  alias Dust.Accounts.User

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :binary
    field :token_prefix, :string, default: "dust_tok"
    field :token_last4, :string
    field :store_access_mode, Ecto.Enum, values: [:all, :selected], default: :selected
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    field :raw_token, :string, virtual: true
    field :scopes, {:array, :string}, virtual: true, default: []
    field :store_ids, {:array, :binary_id}, virtual: true, default: []
    field :store_id, :binary_id, virtual: true
    field :store, :map, virtual: true

    belongs_to :organization, Organization
    belongs_to :created_by, User, foreign_key: :created_by_id
    belongs_to :revoked_by, User, foreign_key: :revoked_by_id

    has_many :scope_grants, ScopeGrant
    has_many :store_grants, StoreGrant

    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> Ecto.Changeset.cast(attrs, [
      :name,
      :token_hash,
      :token_prefix,
      :token_last4,
      :store_access_mode,
      :expires_at,
      :last_used_at,
      :revoked_at,
      :organization_id,
      :created_by_id,
      :revoked_by_id
    ])
    |> Ecto.Changeset.validate_required([
      :name,
      :token_hash,
      :token_prefix,
      :store_access_mode,
      :organization_id
    ])
    |> Ecto.Changeset.unique_constraint(:token_hash)
  end

  def update_changeset(token, attrs) do
    token
    |> Ecto.Changeset.cast(attrs, [:name, :store_access_mode, :expires_at])
    |> Ecto.Changeset.validate_required([:name, :store_access_mode])
  end
end
