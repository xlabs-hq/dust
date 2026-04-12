defmodule Dust.MCP.AuthzTest do
  use Dust.DataCase, async: true

  import Ecto.Query

  alias Dust.Accounts.OrganizationMembership
  alias Dust.IntegrationHelpers
  alias Dust.MCP.Authz
  alias Dust.MCP.Principal
  alias Dust.Repo
  alias Dust.Stores

  setup do
    %{user: user, org: org, store: store, token: rw_token} =
      IntegrationHelpers.create_test_store("authz", "alpha")

    # Re-authenticate to get the preloaded struct the plug would pass along.
    {:ok, authed_rw_token} = Stores.authenticate_token(rw_token.raw_token)

    %{
      user: user,
      org: org,
      store: store,
      rw_token: authed_rw_token,
      full_name: "#{org.slug}/#{store.name}"
    }
  end

  describe "user_session principal" do
    test "allows read on store in user's org", %{user: user, store: store, full_name: full_name} do
      principal = %Principal{kind: :user_session, user: user}
      assert {:ok, resolved} = Authz.authorize_store(principal, full_name, :read)
      assert resolved.id == store.id
    end

    test "allows write on store in user's org", %{user: user, store: store, full_name: full_name} do
      principal = %Principal{kind: :user_session, user: user}
      assert {:ok, resolved} = Authz.authorize_store(principal, full_name, :write)
      assert resolved.id == store.id
    end

    test "denies access when user not in org", %{full_name: full_name} do
      {:ok, stranger} =
        Dust.Accounts.create_user(%{
          email: "stranger-#{System.unique_integer([:positive])}@example.com"
        })

      principal = %Principal{kind: :user_session, user: stranger}
      assert {:error, _} = Authz.authorize_store(principal, full_name, :read)
    end

    test "errors when store not found", %{user: user} do
      principal = %Principal{kind: :user_session, user: user}
      assert {:error, _} = Authz.authorize_store(principal, "nope/missing", :read)
    end

    test "denies access when membership has been soft-deleted",
         %{user: user, org: org, full_name: full_name} do
      principal = %Principal{kind: :user_session, user: user}
      assert {:ok, _} = Authz.authorize_store(principal, full_name, :read)

      {1, _} =
        Repo.update_all(
          from(m in OrganizationMembership,
            where: m.user_id == ^user.id and m.organization_id == ^org.id
          ),
          set: [deleted_at: DateTime.utc_now()]
        )

      assert {:error, _} = Authz.authorize_store(principal, full_name, :read)
    end
  end

  describe "store_token principal" do
    test "allows when token matches store and has read permission", %{
      store: store,
      rw_token: rw_token,
      full_name: full_name
    } do
      principal = %Principal{kind: :store_token, store_token: rw_token}
      assert {:ok, resolved} = Authz.authorize_store(principal, full_name, :read)
      assert resolved.id == store.id
    end

    test "denies write on read-only token", %{
      store: store,
      user: user,
      full_name: full_name
    } do
      {:ok, read_only} =
        Stores.create_store_token(store, %{
          name: "read-only",
          read: true,
          write: false,
          created_by_id: user.id
        })

      {:ok, authed} = Stores.authenticate_token(read_only.raw_token)
      principal = %Principal{kind: :store_token, store_token: authed}
      assert {:error, _} = Authz.authorize_store(principal, full_name, :write)
    end
  end
end
