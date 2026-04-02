defmodule DustWeb.Api.ExportControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    # Clean up SQLite store files
    store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
    File.rm_rf!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "export-api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Export Org", slug: "exportorg"})

    {:ok, store} = Stores.create_store(org, %{name: "mystore"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "export-tok",
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
  end

  describe "GET /api/stores/:org/:store/export" do
    test "exports JSONL by default", %{conn: conn, token: token, store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "key1",
        value: "val1",
        device_id: "d",
        client_op_id: "o1"
      })

      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/exportorg/mystore/export")

      assert resp.status == 200
      assert get_resp_header(resp, "content-type") |> hd() =~ "application/x-ndjson"

      lines = resp.resp_body |> String.split("\n", trim: true)
      assert length(lines) == 2

      header = Jason.decode!(hd(lines))
      assert header["_header"] == true
      assert header["store"] == "exportorg/mystore"
      assert header["entry_count"] == 1
    end

    test "exports JSONL when format=jsonl", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/exportorg/mystore/export?format=jsonl")

      assert resp.status == 200
      assert get_resp_header(resp, "content-type") |> hd() =~ "application/x-ndjson"

      lines = resp.resp_body |> String.split("\n", trim: true)
      header = Jason.decode!(hd(lines))
      assert header["entry_count"] == 0
    end

    test "exports SQLite when format=sqlite", %{conn: conn, token: token, store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "x",
        value: "v",
        device_id: "d",
        client_op_id: "o1"
      })

      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/exportorg/mystore/export?format=sqlite")

      assert resp.status == 200
      assert get_resp_header(resp, "content-type") |> hd() =~ "application/x-sqlite3"

      assert get_resp_header(resp, "content-disposition") |> hd() =~
               "attachment; filename=\"exportorg_mystore.db\""

      # Verify the response body is valid SQLite by writing to temp file
      tmp = Path.join(System.tmp_dir!(), "export_ctrl_#{System.unique_integer([:positive])}.db")
      File.write!(tmp, resp.resp_body)
      assert {:ok, db} = Exqlite.Sqlite3.open(tmp, [:readonly])
      Exqlite.Sqlite3.close(db)
      File.rm(tmp)
    end

    test "returns 404 for non-existent store", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/exportorg/nonexistent/export")

      assert resp.status == 404
    end

    test "returns 403 when token does not match store", %{
      conn: conn,
      org: org,
      user: user
    } do
      # Upgrade to pro so we can create a second store
      org = org |> Ecto.Changeset.change(plan: "pro") |> Dust.Repo.update!()

      {:ok, other_store} = Stores.create_store(org, %{name: "other"})

      {:ok, other_token} =
        Stores.create_store_token(other_store, %{
          name: "other-tok",
          read: true,
          write: true,
          created_by_id: user.id
        })

      # Use other_token to access mystore — should be forbidden
      resp =
        conn
        |> api_conn(other_token)
        |> get("/api/stores/exportorg/mystore/export")

      assert resp.status == 403
    end

    test "returns 401 without authorization header", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/stores/exportorg/mystore/export")

      assert resp.status == 401
    end
  end
end
