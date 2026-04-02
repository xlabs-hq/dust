defmodule DustWeb.Api.ImportControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    # Clean up SQLite store files
    store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
    File.rm_rf!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "import-api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Import Org", slug: "importorg"})

    {:ok, store} = Stores.create_store(org, %{name: "mystore"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "import-tok",
        read: true,
        write: true,
        created_by_id: user.id
      })

    %{org: org, store: store, token: token, user: user}
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
    |> put_req_header("content-type", "application/x-ndjson")
  end

  describe "POST /api/stores/:org/:store/import" do
    test "imports JSONL body successfully", %{conn: conn, token: token, store: store} do
      body =
        [
          ~s({"_header": true, "store": "importorg/mystore", "seq": 1, "entry_count": 2}),
          ~s({"path": "key1", "value": "val1", "type": "string"}),
          ~s({"path": "key2", "value": 42, "type": "integer"})
        ]
        |> Enum.join("\n")

      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/importorg/mystore/import", body)

      assert json_response(resp, 200) == %{"ok" => true, "entries_imported" => 2}

      assert Sync.get_entry(store.id, "key1").value == "val1"
      assert Sync.get_entry(store.id, "key2").value == 42
    end

    test "returns 404 for non-existent store", %{conn: conn, token: token} do
      body = ~s({"path": "a", "value": 1, "type": "integer"})

      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/importorg/nonexistent/import", body)

      assert json_response(resp, 404) == %{"error" => "not_found"}
    end

    test "returns 403 for read-only token", %{conn: conn, store: store, user: user} do
      {:ok, ro_token} =
        Stores.create_store_token(store, %{
          name: "readonly-tok",
          read: true,
          write: false,
          created_by_id: user.id
        })

      body = ~s({"path": "a", "value": 1, "type": "integer"})

      resp =
        conn
        |> api_conn(ro_token)
        |> post("/api/stores/importorg/mystore/import", body)

      assert json_response(resp, 403) == %{"error" => "forbidden"}
    end
  end
end
