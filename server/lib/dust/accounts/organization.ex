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

  @doc """
  Changeset for changing only an organization's plan.

  `:plan` is intentionally excluded from `changeset/2` so it can never be set
  through the normal user-facing flows; plan changes go through this admin path
  and are validated against the known plans in `Dust.Billing.Limits`.
  """
  def plan_changeset(org, attrs) do
    org
    |> Ecto.Changeset.cast(attrs, [:plan])
    |> Ecto.Changeset.validate_required([:plan])
    |> Ecto.Changeset.validate_inclusion(:plan, Dust.Billing.Limits.plan_names())
  end
end
