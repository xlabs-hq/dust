defmodule DustWeb.Plugs.AuthTest do
  use DustWeb.ConnCase, async: true

  alias Dust.Accounts
  alias DustWeb.Plugs.Auth

  defp create_user_and_org(_context) do
    {:ok, user} = Accounts.create_user(%{email: "test@example.com", first_name: "Test"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Test Org", slug: "test-org"})

    token = Accounts.generate_user_session_token(user)
    %{user: user, org: org, token: token}
  end

  describe "fetch_current_scope_for_user/2" do
    setup [:create_user_and_org]

    test "assigns current_scope with user when session has valid token", %{
      conn: conn,
      user: user,
      token: token
    } do
      conn =
        conn
        |> init_test_session(%{user_token: token})
        |> Auth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
    end

    test "assigns nil current_scope when no session token", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Auth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
    end

    test "assigns nil current_scope when session token is invalid", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{user_token: :crypto.strong_rand_bytes(32)})
        |> Auth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
    end
  end

  describe "require_authenticated_user/2" do
    setup [:create_user_and_org]

    test "does not halt when user is authenticated", %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{user_token: token})
        |> Auth.fetch_current_scope_for_user([])
        |> Auth.require_authenticated_user([])

      refute conn.halted
    end

    test "halts and redirects when not authenticated", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> Auth.fetch_current_scope_for_user([])
        |> Auth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/login"
    end
  end

  describe "assign_org_to_scope/2" do
    setup [:create_user_and_org]

    test "assigns organization to scope when user is a member", %{
      conn: conn,
      token: token,
      org: org
    } do
      conn =
        conn
        |> init_test_session(%{user_token: token})
        |> Auth.fetch_current_scope_for_user([])
        |> Map.put(:params, %{"org" => org.slug})
        |> Auth.assign_org_to_scope([])

      assert conn.assigns.current_scope.organization.id == org.id
    end

    test "halts when user is not a member of org", %{conn: conn, token: token} do
      # Create another org the user is NOT a member of
      {:ok, other_org} = Accounts.create_organization(%{name: "Other Org", slug: "other-org"})

      conn =
        conn
        |> init_test_session(%{user_token: token})
        |> fetch_flash()
        |> Auth.fetch_current_scope_for_user([])
        |> Map.put(:params, %{"org" => other_org.slug})
        |> Auth.assign_org_to_scope([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/login"
    end
  end
end
