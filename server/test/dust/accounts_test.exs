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

  describe "find_or_create_user_from_workos/1" do
    defp workos_user_fixture(attrs) do
      defaults = %{
        email_verified: true,
        updated_at: "2026-01-01T00:00:00.000Z",
        created_at: "2026-01-01T00:00:00.000Z"
      }

      struct!(WorkOS.UserManagement.User, Map.merge(defaults, attrs))
    end

    test "creates new user when workos_user is unknown" do
      workos_user =
        workos_user_fixture(%{
          id: "user_test_#{System.unique_integer([:positive])}",
          email: "newmcp@example.com",
          first_name: "New",
          last_name: "MCP"
        })

      assert {:ok, user} = Accounts.find_or_create_user_from_workos(workos_user)
      assert user.email == "newmcp@example.com"
      assert user.workos_id == workos_user.id
    end

    test "links workos_id to existing user matched by email" do
      {:ok, existing} = Accounts.create_user(%{email: "link-me@example.com"})
      assert existing.workos_id == nil

      workos_user =
        workos_user_fixture(%{
          id: "user_brand_new_workos_id_xyz",
          email: "link-me@example.com",
          first_name: "Link",
          last_name: "Me"
        })

      assert {:ok, user} = Accounts.find_or_create_user_from_workos(workos_user)
      assert user.id == existing.id
      assert user.workos_id == "user_brand_new_workos_id_xyz"
    end

    test "returns existing user when called twice with same workos_id" do
      workos_user =
        workos_user_fixture(%{
          id: "user_existing_#{System.unique_integer([:positive])}",
          email: "exists@example.com",
          first_name: "Ex",
          last_name: "Ist"
        })

      assert {:ok, first} = Accounts.find_or_create_user_from_workos(workos_user)
      assert {:ok, second} = Accounts.find_or_create_user_from_workos(workos_user)
      assert first.id == second.id
    end
  end

  describe "user_belongs_to_org?/2" do
    test "returns true when membership exists" do
      {:ok, user} = Accounts.create_user(%{email: "member@example.com"})

      {:ok, org} =
        Accounts.create_organization_with_owner(user, %{name: "Member Org", slug: "memberorg"})

      assert Accounts.user_belongs_to_org?(user, org.id)
    end

    test "returns false when no membership" do
      {:ok, user} = Accounts.create_user(%{email: "outsider@example.com"})

      {:ok, other_user} = Accounts.create_user(%{email: "owner2@example.com"})

      {:ok, org} =
        Accounts.create_organization_with_owner(other_user, %{
          name: "Other Org",
          slug: "otherorg"
        })

      refute Accounts.user_belongs_to_org?(user, org.id)
    end
  end
end
