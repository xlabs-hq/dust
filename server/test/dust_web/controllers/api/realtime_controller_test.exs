defmodule DustWeb.Api.RealtimeControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.Accounts
  alias Dust.Stores

  setup do
    {:ok, user} = Accounts.create_user(%{email: "rt@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "RT Org", slug: "rtorg"})

    {:ok, store} = Stores.create_store(org, %{name: "rtstore"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "rt-tok",
        read: true,
        write: false,
        created_by_id: user.id
      })

    %{token: token}
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
  end

  for path <- ["subscribe", "watch"] do
    @path path

    test "GET /#{@path} returns 426 with WS pointer", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/rtorg/rtstore/#{@path}")

      assert resp.status == 426
      body = Jason.decode!(resp.resp_body)
      assert body["error"] == "upgrade_required"
      assert is_binary(body["detail"])
      assert body["detail"] =~ "WebSocket"
      assert body["ws_url"] =~ ~r{^wss?://}
      assert String.ends_with?(body["ws_url"], "/ws/sync")
    end
  end

  test "/subscribe without bearer token returns 401", %{conn: conn} do
    resp =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/stores/rtorg/rtstore/subscribe")

    assert resp.status == 401
  end
end
