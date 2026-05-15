defmodule DustWeb.WorkOSAuthControllerTest do
  use DustWeb.ConnCase, async: true

  alias Dust.Accounts

  describe "GET /auth/login" do
    test "renders the login page", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")
      assert conn.status == 200
    end
  end

  describe "GET /auth/authorize (dev bypass)" do
    setup do
      # Enable dev bypass for testing
      original = Application.get_env(:dust, :dev_bypass_auth, false)
      Application.put_env(:dust, :dev_bypass_auth, true)
      on_exit(fn -> Application.put_env(:dust, :dev_bypass_auth, original) end)
      :ok
    end

    test "auto-creates dev user and logs in", %{conn: conn} do
      conn = get(conn, ~p"/auth/authorize")

      # Should redirect to the dev user's org
      assert redirected_to(conn) =~ "/"

      # Dev user should be created
      assert user = Accounts.get_user_by_email("dev@dust.local")
      assert user.first_name == "Dev"

      # User should have an auto-created org
      orgs = Accounts.list_user_organizations(user)
      assert length(orgs) >= 1
    end

    test "reuses existing dev user on subsequent logins", %{conn: conn} do
      # First login
      _conn1 = get(conn, ~p"/auth/authorize")
      user1 = Accounts.get_user_by_email("dev@dust.local")

      # Second login
      conn2 = get(build_conn(), ~p"/auth/authorize")
      assert redirected_to(conn2) =~ "/"

      user2 = Accounts.get_user_by_email("dev@dust.local")
      assert user1.id == user2.id
    end

    test "honors :user_return_to pointing at /oauth/authorize/continue", %{conn: conn} do
      return_to = "/oauth/authorize/continue?flow=abc123"

      conn =
        conn
        |> init_test_session(%{user_return_to: return_to})
        |> get(~p"/auth/authorize")

      assert redirected_to(conn) == return_to
    end

    test "ignores :user_return_to that is not on the allowlist", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{user_return_to: "/admin"})
        |> get(~p"/auth/authorize")

      # Falls back to signed_in_path/1 (the dev user's org), not "/admin".
      refute redirected_to(conn) == "/admin"
      assert redirected_to(conn) =~ "/"
    end
  end

  describe "DELETE /auth/logout" do
    test "clears session and redirects to login", %{conn: conn} do
      # First create a user and log them in
      {:ok, user} = Accounts.create_user(%{email: "logout@example.com"})
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> init_test_session(%{user_token: token})
        |> delete(~p"/auth/logout")

      assert redirected_to(conn) == "/auth/login"

      # Token should be deleted
      assert Accounts.get_user_by_session_token(token) == nil
    end
  end
end
