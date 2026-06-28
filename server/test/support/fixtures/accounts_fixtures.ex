defmodule Dust.AccountsFixtures do
  @moduledoc """
  Fixtures for `Dust.Accounts`.
  """

  alias Dust.Accounts

  def unique_user_email,
    do: "user-#{System.unique_integer([:positive])}@example.com"

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: unique_user_email()})
      |> Accounts.create_user_with_org()

    user
  end

  def unique_org_slug, do: "org-#{System.unique_integer([:positive])}"

  @doc """
  Creates an organization owned by `user` (a fresh user is created if none is
  given). Returns the organization struct.
  """
  def organization_fixture(attrs \\ %{}, user \\ nil) do
    owner = user || user_fixture()
    slug = Map.get(attrs, :slug, unique_org_slug())
    attrs = Enum.into(attrs, %{name: slug, slug: slug})

    {:ok, org} = Accounts.create_organization_with_owner(owner, attrs)
    org
  end
end
