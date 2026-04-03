defmodule DustWeb.Api.DiffControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
    File.rm_rf!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "diff-api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Diff Org", slug: "difforg"})

    {:ok, store} = Stores.create_store(org, %{name: "mystore"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "diff-tok",
        read: true,
        write: true,
        created_by_id: user.id
      })

    # Write some data to create a sequence history
    Sync.write(store.id, %{
      op: :set,
      path: "key1",
      value: "val1",
      device_id: "d",
      client_op_id: "o1"
    })

    Sync.write(store.id, %{
      op: :set,
      path: "key2",
      value: "val2",
      device_id: "d",
      client_op_id: "o2"
    })

    %{org: org, store: store, token: token, user: user}
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
  end

  describe "GET /api/stores/:org/:store/diff" do
    test "successful diff with from_seq and to_seq", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/difforg/mystore/diff?from_seq=0&to_seq=2")

      body = json_response(resp, 200)
      assert body["from_seq"] == 0
      assert body["to_seq"] == 2
      assert is_list(body["changes"])
      assert length(body["changes"]) == 2
    end

    test "defaults to_seq to current when omitted", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/difforg/mystore/diff?from_seq=0")

      body = json_response(resp, 200)
      assert body["from_seq"] == 0
      assert body["to_seq"] == 2
      assert length(body["changes"]) == 2
    end

    test "returns 404 for nonexistent store", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/difforg/nonexistent/diff?from_seq=0")

      assert json_response(resp, 404) == %{"error" => "not_found"}
    end
  end
end
