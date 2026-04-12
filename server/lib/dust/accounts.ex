defmodule Dust.Accounts do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Accounts.{User, UserToken, Organization, OrganizationMembership}

  # --- Users ---

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

  def link_user_to_workos(%User{} = user, workos_id) do
    user
    |> User.changeset(%{workos_id: workos_id})
    |> Repo.update()
  end

  @doc """
  Find or create a local user from a WorkOS user.

  Accepts either a `%WorkOS.UserManagement.User{}` struct (returned by the SDK)
  or a map with string keys (returned by raw API calls). Looks up by
  `workos_id` first, then falls back to email lookup and links. If no user is
  found, creates a new user along with a personal organization.
  """
  def find_or_create_user_from_workos(%{"id" => workos_id, "email" => email} = workos_user) do
    first_name = workos_user["first_name"]
    last_name = workos_user["last_name"]

    case get_user_by_workos_id(workos_id) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case get_user_by_email(email) do
          %User{} = user ->
            link_user_to_workos(user, workos_id)

          nil ->
            create_user_with_org(%{
              workos_id: workos_id,
              email: email,
              first_name: first_name,
              last_name: last_name
            })
        end
    end
  end

  def find_or_create_user_from_workos(%{id: workos_id, email: email} = workos_user) do
    find_or_create_user_from_workos(%{
      "id" => workos_id,
      "email" => email,
      "first_name" => Map.get(workos_user, :first_name),
      "last_name" => Map.get(workos_user, :last_name)
    })
  end

  @doc """
  Create a user together with a personal organization derived from their email.
  If the organization creation fails for any reason (e.g. slug collision), the
  user is still returned successfully.
  """
  def create_user_with_org(attrs) do
    with {:ok, user} <- create_user(attrs) do
      slug = email_to_slug(attrs.email)

      case create_organization_with_owner(user, %{name: slug, slug: slug}) do
        {:ok, _org} -> {:ok, user}
        {:error, _} -> {:ok, user}
      end
    end
  end

  defp email_to_slug(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
    |> case do
      "" -> "user"
      slug -> slug
    end
  end

  # --- Session tokens ---

  @doc """
  Generates a session token for a user.
  Returns the raw token (to be stored in the session cookie).
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user associated with the given session token.
  Returns `{user, token_inserted_at}` or `nil`.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the session token from the database.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Deletes all session tokens for a user.
  """
  def delete_user_sessions(user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
    :ok
  end

  # --- Organizations ---

  def get_organization_by_slug!(slug) do
    Repo.get_by!(Organization, slug: slug)
  end

  def get_organization_by_workos_id(workos_org_id) do
    Repo.get_by(Organization, workos_organization_id: workos_org_id)
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

  # --- Memberships ---

  def get_organization_membership(user, org) do
    Repo.get_by(OrganizationMembership, user_id: user.id, organization_id: org.id)
  end

  def ensure_membership(%User{} = user, %Organization{} = org, role \\ :member) do
    case get_organization_membership(user, org) do
      nil ->
        %OrganizationMembership{}
        |> OrganizationMembership.changeset(%{
          user_id: user.id,
          organization_id: org.id,
          role: role
        })
        |> Repo.insert()

      membership ->
        {:ok, membership}
    end
  end

  def list_organization_members(%Organization{} = org) do
    from(m in OrganizationMembership,
      where: m.organization_id == ^org.id and is_nil(m.deleted_at),
      join: u in assoc(m, :user),
      preload: [:user],
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
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

  def user_belongs_to_org?(%User{id: user_id}, org_id) when is_binary(org_id) do
    Repo.exists?(
      from m in OrganizationMembership,
        where: m.user_id == ^user_id and m.organization_id == ^org_id
    )
  end
end
