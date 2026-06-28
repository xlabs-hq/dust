defmodule Dust.AccountsAdminTest do
  use Dust.DataCase, async: true

  import Dust.AccountsFixtures

  alias Dust.Accounts
  alias Dust.Repo
  alias Dust.Stores.Store

  # Inserts a bare store row for counting/listing without opening the per-store
  # SQLite database (which would require an async: false test).
  defp store_row!(org, name) do
    Repo.insert!(%Store{organization_id: org.id, name: name, status: :active})
  end

  describe "list_organizations/0" do
    test "returns organizations with member and store counts" do
      org = organization_fixture(%{slug: "acme"})
      _store = store_row!(org, "store-one")

      row = Enum.find(Accounts.list_organizations(), &(&1.id == org.id))

      assert row.slug == "acme"
      assert row.plan == "free"
      assert row.member_count == 1
      assert row.store_count == 1
    end

    test "counts zero stores and excludes soft-deleted-only orgs gracefully" do
      org = organization_fixture(%{slug: "empty-org"})

      row = Enum.find(Accounts.list_organizations(), &(&1.id == org.id))

      assert row.member_count == 1
      assert row.store_count == 0
    end
  end

  describe "list_users/0" do
    test "returns users with an organization count" do
      user = user_fixture(%{email: "counted@example.com"})

      row = Enum.find(Accounts.list_users(), &(&1.id == user.id))

      assert row.email == "counted@example.com"
      # user_fixture creates a personal organization
      assert row.org_count == 1
    end
  end

  describe "update_organization_plan/2" do
    test "updates to a known plan" do
      org = organization_fixture()

      assert {:ok, updated} = Accounts.update_organization_plan(org, "pro")
      assert updated.plan == "pro"
      assert Accounts.get_organization!(org.id).plan == "pro"
    end

    test "rejects an unknown plan" do
      org = organization_fixture()

      assert {:error, changeset} = Accounts.update_organization_plan(org, "enterprise")
      refute changeset.valid?
      assert Accounts.get_organization!(org.id).plan == "free"
    end
  end

  describe "list_user_memberships/1" do
    test "returns memberships with organization preloaded and role" do
      user = user_fixture()
      _org = organization_fixture(%{slug: "second-org"}, user)

      memberships = Accounts.list_user_memberships(user)

      slugs = Enum.map(memberships, & &1.organization.slug)
      assert "second-org" in slugs
      assert Enum.all?(memberships, &(&1.role == :owner))
    end
  end
end
