defmodule Dust.Accounts.OrganizationMembership do
  use Dust.Schema

  schema "organization_memberships" do
    field :role, Ecto.Enum, values: [:owner, :admin, :member, :guest]
    field :deleted_at, :utc_datetime_usec

    belongs_to :user, Dust.Accounts.User
    belongs_to :organization, Dust.Accounts.Organization

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> Ecto.Changeset.cast(attrs, [:role, :user_id, :organization_id])
    |> Ecto.Changeset.validate_required([:role, :user_id, :organization_id])
    |> Ecto.Changeset.unique_constraint([:user_id, :organization_id],
      name: :org_memberships_user_org_active
    )
  end
end
