defmodule Dust.Accounts do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Accounts.{User, Organization, OrganizationMembership}

  # Users

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) do
    Repo.get_by(User, email: email)
  end

  def get_user_by_workos_id(workos_id) do
    Repo.get_by(User, workos_id: workos_id)
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  # Organizations

  def get_organization_by_slug!(slug) do
    Repo.get_by!(Organization, slug: slug)
  end

  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  def create_organization_with_owner(%User{} = user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:organization, Organization.changeset(%Organization{}, attrs))
    |> Ecto.Multi.insert(:membership, fn %{organization: org} ->
      OrganizationMembership.changeset(%OrganizationMembership{}, %{
        user_id: user.id,
        organization_id: org.id,
        role: :owner
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: org}} -> {:ok, org}
      {:error, _, changeset, _} -> {:error, changeset}
    end
  end

  # Memberships

  def get_organization_membership(user, org) do
    Repo.get_by(OrganizationMembership, user_id: user.id, organization_id: org.id)
  end

  def ensure_membership(%User{} = user, %Organization{} = org, role \\ :member) do
    case get_organization_membership(user, org) do
      nil ->
        %OrganizationMembership{}
        |> OrganizationMembership.changeset(%{user_id: user.id, organization_id: org.id, role: role})
        |> Repo.insert()

      membership ->
        {:ok, membership}
    end
  end

  def list_user_organizations(%User{} = user) do
    from(o in Organization,
      join: m in OrganizationMembership,
      on: m.organization_id == o.id,
      where: m.user_id == ^user.id and is_nil(m.deleted_at),
      select: o
    )
    |> Repo.all()
  end
end
