defmodule DustWeb.DashboardControllerTest do
  use DustWeb.ConnCase

  alias Dust.{Accounts, Stores}

  setup %{conn: conn} do
    {:ok, user} = Accounts.create_user(%{email: "dash@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "dash-org"})
    token = Accounts.generate_user_session_token(user)

    conn =
      conn
      |> init_test_session(%{user_token: token})

    %{conn: conn, user: user, org: org}
  end

  test "GET /:org shows dashboard with stats", %{conn: conn, org: org, user: user} do
    # Create a store and token to verify stats
    {:ok, store} = Stores.create_store(org, %{name: "test-store"})
    {:ok, _token} = Stores.create_store_token(store, %{name: "t1", read: true, created_by_id: user.id})

    conn = get(conn, ~p"/#{org.slug}")
    assert conn.status == 200

    # The Inertia response should contain the stats
    body = conn.resp_body
    assert body =~ "Dashboard"
  end

  test "GET /:org requires authentication", %{conn: _conn} do
    conn = build_conn()
    conn = get(conn, ~p"/dash-org")
    assert redirected_to(conn) == "/auth/login"
  end
end
