defmodule DustWeb.AuditControllerTest do
  use DustWeb.ConnCase

  alias Dust.{Accounts, Stores, Sync}

  setup %{conn: conn} do
    {:ok, user} = Accounts.create_user(%{email: "audit-ctrl@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Test", slug: "audit-ctrl-org"})

    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    token = Accounts.generate_user_session_token(user)

    conn = conn |> init_test_session(%{user_token: token})

    # Write a few ops
    for i <- 1..3 do
      Sync.write(store.id, %{
        op: :set,
        path: "key#{i}",
        value: "val#{i}",
        device_id: "dev_1",
        client_op_id: "op_#{i}"
      })
    end

    %{conn: conn, user: user, org: org, store: store}
  end

  describe "index" do
    test "renders audit log page", %{conn: conn, org: org, store: store} do
      conn = get(conn, ~p"/#{org.slug}/stores/#{store.name}/log")
      assert conn.status == 200
      assert conn.resp_body =~ "AuditLog"
    end

    test "accepts filter params", %{conn: conn, org: org, store: store} do
      conn =
        get(conn, ~p"/#{org.slug}/stores/#{store.name}/log", %{
          path: "key1",
          op: "set",
          device_id: "dev_1"
        })

      assert conn.status == 200
    end

    test "accepts pagination params", %{conn: conn, org: org, store: store} do
      conn = get(conn, ~p"/#{org.slug}/stores/#{store.name}/log", %{page: "2", limit: "1"})
      assert conn.status == 200
    end

    test "404s for nonexistent store", %{conn: conn, org: org} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, ~p"/#{org.slug}/stores/nonexistent/log")
      end
    end
  end
end
