defmodule Dust.AccountsTest do
  use Dust.DataCase, async: true

  alias Dust.Accounts

  describe "users" do
    test "create_user/1 with valid attrs" do
      assert {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
      assert user.email == "test@example.com"
      assert user.id != nil
    end

    test "create_user/1 rejects duplicate email" do
      Accounts.create_user(%{email: "dupe@example.com"})
      assert {:error, changeset} = Accounts.create_user(%{email: "dupe@example.com"})
      assert errors_on(changeset).email != nil
    end
  end

  describe "organizations" do
    test "create_organization_with_owner/2 creates org and membership" do
      {:ok, user} = Accounts.create_user(%{email: "owner@example.com"})

      assert {:ok, org} =
               Accounts.create_organization_with_owner(user, %{name: "James", slug: "james"})

      assert org.slug == "james"

      membership = Accounts.get_organization_membership(user, org)
      assert membership.role == :owner
    end

    test "slug must be lowercase alphanumeric" do
      {:ok, user} = Accounts.create_user(%{email: "test@example.com"})

      assert {:error, _} =
               Accounts.create_organization_with_owner(user, %{name: "Bad", slug: "Bad Slug!"})
    end
  end
end
