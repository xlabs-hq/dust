defmodule DustWeb.Api.EntriesApiControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.Accounts
  alias Dust.Stores
  alias Dust.Sync

  setup do
    store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
    File.rm_rf!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "entries-api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Entries Org", slug: "entriesorg"})

    {:ok, store} = Stores.create_store(org, %{name: "mystore"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "entries-tok",
        read: true,
        write: true,
        created_by_id: user.id
      })

    seed_entry(store, "users.alice.email", "alice@example.com")
    seed_entry(store, "users.alice.name", "Alice")
    seed_entry(store, "users.bob.name", "Bob")

    %{org: org, store: store, token: token, user: user}
  end

  defp seed_entry(store, path, value) do
    {:ok, _op} =
      Sync.write(store.id, %{
        op: :set,
        path: path,
        value: value,
        device_id: "test-device",
        client_op_id: "seed-#{path}"
      })
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
  end

  describe "GET /api/stores/:org/:store/entries" do
    test "returns paginated entries with revision field", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&limit=10")

      body = json_response(resp, 200)
      assert length(body["items"]) == 3

      first = hd(body["items"])
      assert first["path"] =~ "users."
      assert is_integer(first["revision"])
      assert Map.has_key?(first, "value")
      assert Map.has_key?(first, "type")
      assert body["next_cursor"] == nil
    end

    test "select=keys returns list of path strings", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&select=keys")

      body = json_response(resp, 200)

      assert body["items"] == [
               "users.alice.email",
               "users.alice.name",
               "users.bob.name"
             ]
    end

    test "select=prefixes with valid pattern returns unique next-segment prefixes", %{
      conn: conn,
      token: token
    } do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&select=prefixes")

      body = json_response(resp, 200)
      assert body["items"] == ["users.alice", "users.bob"]
    end

    test "select=prefixes with invalid pattern returns 400", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.*&select=prefixes")

      assert %{"error" => "invalid_pattern_for_prefixes"} = json_response(resp, 400)
    end

    test "paginates via next_cursor with limit=1", %{conn: conn, token: token} do
      resp1 =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&select=keys&limit=1")

      body1 = json_response(resp1, 200)
      assert length(body1["items"]) == 1
      assert body1["next_cursor"] != nil

      resp2 =
        conn
        |> api_conn(token)
        |> get(
          "/api/stores/entriesorg/mystore/entries?pattern=users.**&select=keys&limit=1&after=#{body1["next_cursor"]}"
        )

      body2 = json_response(resp2, 200)
      assert length(body2["items"]) == 1
      assert body2["items"] != body1["items"]
    end

    test "returns 401 without Bearer token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/stores/entriesorg/mystore/entries?pattern=**")

      assert resp.status == 401
    end
  end
end
