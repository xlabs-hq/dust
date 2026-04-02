defmodule Dust.Accounts.Organization do
  use Dust.Schema

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :plan, :string, default: "free"
    field :workos_organization_id, :string

    has_many :organization_memberships, Dust.Accounts.OrganizationMembership
    has_many :users, through: [:organization_memberships, :user]

    timestamps()
  end

  def changeset(org, attrs) do
    org
    |> Ecto.Changeset.cast(attrs, [:name, :slug, :workos_organization_id])
    |> Ecto.Changeset.validate_required([:name, :slug])
    |> Ecto.Changeset.unique_constraint(:slug)
    |> Ecto.Changeset.unique_constraint(:workos_organization_id)
    |> Ecto.Changeset.validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
  end
end
