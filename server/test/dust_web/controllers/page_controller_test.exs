defmodule DustWeb.PageControllerTest do
  use DustWeb.ConnCase

  alias Dust.Accounts

  test "GET /:org requires authentication", %{conn: conn} do
    conn = get(conn, ~p"/test-org")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /:org renders home when authenticated", %{conn: conn} do
    {:ok, user} = Accounts.create_user(%{email: "page@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "test-org"})
    token = Accounts.generate_user_session_token(user)

    conn =
      conn
      |> init_test_session(%{user_token: token})
      |> get(~p"/#{org.slug}")

    assert conn.status == 200
  end
end
