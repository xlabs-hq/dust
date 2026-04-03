defmodule DustWeb.Api.WebhookControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.{Accounts, Stores, Webhooks}

  setup do
    store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
    File.rm_rf!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "webhook-api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Webhook Org", slug: "webhookorg"})

    {:ok, store} = Stores.create_store(org, %{name: "mystore"})

    {:ok, rw_token} =
      Stores.create_store_token(store, %{
        name: "rw-tok",
        read: true,
        write: true,
        created_by_id: user.id
      })

    {:ok, ro_token} =
      Stores.create_store_token(store, %{
        name: "ro-tok",
        read: true,
        write: false,
        created_by_id: user.id
      })

    %{org: org, store: store, rw_token: rw_token, ro_token: ro_token, user: user}
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
  end

  describe "POST /api/stores/:org/:store/webhooks (create)" do
    test "creates webhook and returns secret", %{conn: conn, rw_token: token} do
      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/webhookorg/mystore/webhooks", %{url: "https://example.com/hook"})

      body = json_response(resp, 201)
      assert body["url"] == "https://example.com/hook"
      assert body["secret"] =~ "whsec_"
      assert body["id"]
      assert body["active"] == true
    end

    test "returns 403 for read-only token", %{conn: conn, ro_token: token} do
      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/webhookorg/mystore/webhooks", %{url: "https://example.com/hook"})

      assert json_response(resp, 403) == %{"error" => "forbidden"}
    end

    test "returns 422 for invalid URL", %{conn: conn, rw_token: token} do
      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/webhookorg/mystore/webhooks", %{url: "not-a-url"})

      assert resp.status == 422
    end
  end

  describe "GET /api/stores/:org/:store/webhooks (index)" do
    test "lists webhooks without secrets", %{conn: conn, rw_token: token, store: store} do
      {:ok, _wh} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/webhookorg/mystore/webhooks")

      body = json_response(resp, 200)
      assert length(body["webhooks"]) == 1
      webhook = hd(body["webhooks"])
      assert webhook["url"] == "https://example.com/hook"
      refute Map.has_key?(webhook, "secret")
    end

    test "returns 401 without token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/stores/webhookorg/mystore/webhooks")

      assert resp.status == 401
    end
  end

  describe "DELETE /api/stores/:org/:store/webhooks/:id (delete)" do
    test "removes webhook", %{conn: conn, rw_token: token, store: store} do
      {:ok, wh} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

      resp =
        conn
        |> api_conn(token)
        |> delete("/api/stores/webhookorg/mystore/webhooks/#{wh.id}")

      assert json_response(resp, 200) == %{"ok" => true}
      assert Webhooks.list_webhooks(store) == []
    end

    test "returns 404 for wrong ID", %{conn: conn, rw_token: token} do
      resp =
        conn
        |> api_conn(token)
        |> delete("/api/stores/webhookorg/mystore/webhooks/#{Ecto.UUID.generate()}")

      assert json_response(resp, 404) == %{"error" => "not_found"}
    end
  end

  describe "POST /api/stores/:org/:store/webhooks/:id/ping (ping)" do
    test "returns 404 for nonexistent webhook ID", %{conn: conn, rw_token: token} do
      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/webhookorg/mystore/webhooks/#{Ecto.UUID.generate()}/ping")

      assert json_response(resp, 404) == %{"error" => "not_found"}
    end

    test "returns 403 for read-only token (Bug 4)", %{conn: conn, ro_token: token, store: store} do
      {:ok, wh} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/webhookorg/mystore/webhooks/#{wh.id}/ping")

      assert json_response(resp, 403) == %{"error" => "forbidden"}
    end
  end

  describe "GET /api/stores/:org/:store/webhooks/:id/deliveries (deliveries)" do
    test "returns delivery log", %{conn: conn, rw_token: token, store: store} do
      {:ok, wh} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

      {:ok, _delivery} =
        Webhooks.record_delivery(wh.id, %{
          store_seq: 1,
          status_code: 200,
          response_ms: 42
        })

      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/webhookorg/mystore/webhooks/#{wh.id}/deliveries")

      body = json_response(resp, 200)
      assert length(body["deliveries"]) == 1
      delivery = hd(body["deliveries"])
      assert delivery["status_code"] == 200
      assert delivery["response_ms"] == 42
    end
  end
end
