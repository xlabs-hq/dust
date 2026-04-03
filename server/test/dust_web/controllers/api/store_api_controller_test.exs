defmodule DustWeb.Api.StoreApiControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.{Accounts, Stores}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "API Test", slug: "apitest"})

    {:ok, store} = Stores.create_store(org, %{name: "existing"})

    {:ok, rw_token} =
      Stores.create_store_token(store, %{
        name: "rw-api",
        read: true,
        write: true,
        created_by_id: user.id
      })

    {:ok, ro_token} =
      Stores.create_store_token(store, %{
        name: "ro-api",
        read: true,
        write: false,
        created_by_id: user.id
      })

    %{org: org, store: store, rw_token: rw_token, ro_token: ro_token}
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
  end

  describe "GET /api/stores" do
    test "lists stores for the token's org", %{conn: conn, rw_token: token} do
      conn = conn |> api_conn(token) |> get("/api/stores")

      assert conn.status == 200
      body = json_response(conn, 200)
      assert length(body["stores"]) >= 1
      assert Enum.any?(body["stores"], fn s -> s["name"] == "existing" end)
    end

    test "returns 401 without token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/stores")

      assert conn.status == 401
    end
  end

  describe "POST /api/stores" do
    test "creates a store with write token on pro plan", %{conn: conn, org: org, rw_token: token} do
      # Upgrade to pro so we can create more than 1 store
      org |> Ecto.Changeset.change(plan: "pro") |> Dust.Repo.update!()

      conn = conn |> api_conn(token) |> post("/api/stores", %{name: "new-store"})

      assert conn.status == 201
      body = json_response(conn, 201)
      assert body["name"] == "new-store"
      assert body["full_name"] == "apitest/new-store"
    end

    test "creates an ephemeral store with TTL", %{conn: conn, org: org, rw_token: token} do
      org |> Ecto.Changeset.change(plan: "pro") |> Dust.Repo.update!()

      conn = conn |> api_conn(token) |> post("/api/stores", %{name: "ephemeral", ttl: 3600})

      assert conn.status == 201
      body = json_response(conn, 201)
      assert body["name"] == "ephemeral"
      assert body["expires_at"] != nil
    end

    test "rejects create when store limit reached on free plan", %{conn: conn, rw_token: token} do
      conn = conn |> api_conn(token) |> post("/api/stores", %{name: "second-store"})

      assert conn.status == 402
      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["dimension"] == "stores"
    end

    test "rejects create with read-only token", %{conn: conn, ro_token: token} do
      conn = conn |> api_conn(token) |> post("/api/stores", %{name: "forbidden"})

      assert conn.status == 403
    end
  end

  describe "token API" do
    test "lists tokens", %{conn: conn, rw_token: token} do
      conn = conn |> api_conn(token) |> get("/api/tokens")

      assert conn.status == 200
      body = json_response(conn, 200)
      assert length(body["tokens"]) >= 1
    end

    test "creates a token", %{conn: conn, rw_token: token, store: store} do
      conn =
        conn
        |> api_conn(token)
        |> post("/api/tokens", %{store_name: store.name, name: "new-tok", read: true, write: true})

      assert conn.status == 201
      body = json_response(conn, 201)
      assert body["name"] == "new-tok"
      assert String.starts_with?(body["raw_token"], "dust_tok_")
    end

    test "delete requires write permission", %{conn: conn, ro_token: token, store: store} do
      {:ok, target} =
        Stores.create_store_token(store, %{
          name: "target",
          read: true,
          created_by_id: token.created_by_id
        })

      conn = conn |> api_conn(token) |> delete("/api/tokens/#{target.id}")
      assert conn.status == 403
    end

    test "delete returns 404 for nonexistent token", %{conn: conn, rw_token: token} do
      conn = conn |> api_conn(token) |> delete("/api/tokens/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end

    test "delete scoped to org — cannot delete tokens from other orgs", %{
      conn: conn,
      rw_token: token
    } do
      # Create another org with its own token
      {:ok, user2} = Accounts.create_user(%{email: "other@example.com"})

      {:ok, org2} =
        Accounts.create_organization_with_owner(user2, %{name: "Other", slug: "other"})

      {:ok, store2} = Stores.create_store(org2, %{name: "s2"})

      {:ok, other_token} =
        Stores.create_store_token(store2, %{name: "other", read: true, created_by_id: user2.id})

      # Try to delete the other org's token — should get 404 (not found in our org)
      conn = conn |> api_conn(token) |> delete("/api/tokens/#{other_token.id}")
      assert conn.status == 404
    end

    test "deletes a token", %{conn: conn, rw_token: token, store: store} do
      {:ok, to_delete} =
        Stores.create_store_token(store, %{
          name: "delete-me",
          read: true,
          created_by_id: token.created_by_id
        })

      conn = conn |> api_conn(token) |> delete("/api/tokens/#{to_delete.id}")

      assert conn.status == 200
      assert json_response(conn, 200)["ok"] == true
    end
  end
end
