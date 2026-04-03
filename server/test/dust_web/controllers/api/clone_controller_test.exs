defmodule DustWeb.Api.CloneControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
    File.rm_rf!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "clone-api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Clone Org", slug: "cloneorg"})

    # Upgrade to pro so we can create multiple stores
    org = org |> Ecto.Changeset.change(plan: "pro") |> Dust.Repo.update!()

    {:ok, store} = Stores.create_store(org, %{name: "source"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "clone-tok",
        read: true,
        write: true,
        created_by_id: user.id
      })

    # Write some data into the source store
    Sync.write(store.id, %{
      op: :set,
      path: "key1",
      value: "val1",
      device_id: "d",
      client_op_id: "o1"
    })

    %{org: org, store: store, token: token, user: user}
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
    |> put_req_header("content-type", "application/json")
  end

  describe "POST /api/stores/:org/:store/clone" do
    test "successful clone on pro plan", %{conn: conn, token: token, org: org} do
      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/cloneorg/source/clone", %{name: "cloned"})

      assert %{"ok" => true, "store" => store_data} = json_response(resp, 201)
      assert store_data["name"] == "cloned"
      assert store_data["full_name"] == "cloneorg/cloned"

      # Verify cloned data exists
      cloned_store = Stores.get_store_by_name(org, "cloned")
      assert cloned_store != nil
      assert Sync.get_entry(cloned_store.id, "key1").value == "val1"
    end

    test "returns 404 for nonexistent source store", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> post("/api/stores/cloneorg/nonexistent/clone", %{name: "cloned"})

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

      resp =
        conn
        |> api_conn(ro_token)
        |> post("/api/stores/cloneorg/source/clone", %{name: "cloned"})

      assert json_response(resp, 403) == %{"error" => "forbidden"}
    end
  end
end
