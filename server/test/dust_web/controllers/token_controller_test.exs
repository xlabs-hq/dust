defmodule DustWeb.TokenControllerTest do
  use DustWeb.ConnCase

  alias Dust.{Accounts, Stores}

  setup %{conn: conn} do
    {:ok, user} = Accounts.create_user(%{email: "token@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "token-org"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    token = Accounts.generate_user_session_token(user)

    conn =
      conn
      |> init_test_session(%{user_token: token})

    %{conn: conn, user: user, org: org, store: store}
  end

  describe "index" do
    test "lists tokens for the org", %{conn: conn, org: org, store: store, user: user} do
      {:ok, _token} =
        Stores.create_store_token(store, %{name: "test-tok", read: true, created_by_id: user.id})

      conn = get(conn, ~p"/#{org.slug}/tokens")
      assert conn.status == 200
      assert conn.resp_body =~ "Tokens"
    end
  end

  describe "create" do
    test "creates a token and shows it", %{conn: conn, org: org, store: store} do
      conn =
        post(conn, ~p"/#{org.slug}/tokens", %{
          name: "my-token",
          store_name: store.name,
          read: "true",
          write: "false"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "dust_tok_"
    end
  end

  describe "delete" do
    test "revokes a token and redirects", %{conn: conn, org: org, store: store, user: user} do
      {:ok, token} =
        Stores.create_store_token(store, %{name: "delete-me", read: true, created_by_id: user.id})

      conn = delete(conn, ~p"/#{org.slug}/tokens/#{token.id}")
      assert redirected_to(conn) == "/#{org.slug}/tokens"

      # Verify the token is gone
      assert {:error, :invalid_token} = Stores.authenticate_token(token.raw_token)
    end
  end
end
