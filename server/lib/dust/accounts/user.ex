defmodule Dust.Accounts.User do
  use Dust.Schema

  schema "users" do
    field :email, :string
    field :workos_id, :string
    field :first_name, :string
    field :last_name, :string

    has_many :organization_memberships, Dust.Accounts.OrganizationMembership
    has_many :organizations, through: [:organization_memberships, :organization]

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> Ecto.Changeset.cast(attrs, [:email, :workos_id, :first_name, :last_name])
    |> Ecto.Changeset.validate_required([:email])
    |> Ecto.Changeset.unique_constraint(:email)
    |> Ecto.Changeset.unique_constraint(:workos_id)
  end
end
