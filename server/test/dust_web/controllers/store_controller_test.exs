defmodule DustWeb.StoreControllerTest do
  use DustWeb.ConnCase

  alias Dust.{Accounts, Stores}

  setup %{conn: conn} do
    {:ok, user} = Accounts.create_user(%{email: "store@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "store-org"})
    token = Accounts.generate_user_session_token(user)

    conn =
      conn
      |> init_test_session(%{user_token: token})

    %{conn: conn, user: user, org: org}
  end

  describe "index" do
    test "lists stores for the org", %{conn: conn, org: org} do
      {:ok, _store} = Stores.create_store(org, %{name: "blog"})

      conn = get(conn, ~p"/#{org.slug}/stores")
      assert conn.status == 200
      assert conn.resp_body =~ "Stores"
    end

    test "renders empty state when no stores", %{conn: conn, org: org} do
      conn = get(conn, ~p"/#{org.slug}/stores")
      assert conn.status == 200
    end
  end

  describe "show" do
    test "shows store detail", %{conn: conn, org: org} do
      {:ok, store} = Stores.create_store(org, %{name: "blog"})

      conn = get(conn, ~p"/#{org.slug}/stores/#{store.name}")
      assert conn.status == 200
      assert conn.resp_body =~ "blog"
    end

    test "404s for nonexistent store", %{conn: conn, org: org} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, ~p"/#{org.slug}/stores/nonexistent")
      end
    end
  end

  describe "create" do
    test "creates a store and redirects", %{conn: conn, org: org} do
      conn = post(conn, ~p"/#{org.slug}/stores", %{name: "new-store"})
      assert redirected_to(conn) == "/#{org.slug}/stores/new-store"

      # Verify store was created
      store = Stores.get_store_by_org_and_name!(org, "new-store")
      assert store.name == "new-store"
    end

    test "shows errors for invalid name", %{conn: conn, org: org} do
      conn = post(conn, ~p"/#{org.slug}/stores", %{name: "INVALID NAME"})
      assert conn.status == 200
      # Should re-render the create page with errors
    end
  end
end
