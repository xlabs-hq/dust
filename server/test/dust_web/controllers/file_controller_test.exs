defmodule DustWeb.FileControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.{Accounts, Files, Stores}

  setup do
    # Clean up test blobs directory
    blob_dir = Files.blob_dir()
    File.rm_rf!(blob_dir)
    on_exit(fn -> File.rm_rf!(blob_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "filetest@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "filetest"})
    {:ok, store} = Stores.create_store(org, %{name: "files"})

    {:ok, rw_token} =
      Stores.create_store_token(store, %{
        name: "rw",
        read: true,
        write: true,
        created_by_id: user.id
      })

    {:ok, ro_token} =
      Stores.create_store_token(store, %{
        name: "ro",
        read: true,
        write: false,
        created_by_id: user.id
      })

    %{store: store, rw_token: rw_token, ro_token: ro_token}
  end

  describe "GET /api/files/:hash" do
    test "downloads a blob with correct content type", %{conn: conn, rw_token: token} do
      {:ok, ref} = Files.upload("hello file", filename: "hello.txt", content_type: "text/plain")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token.raw_token}")
        |> get("/api/files/#{URI.encode(ref["hash"])}")

      assert conn.status == 200
      assert conn.resp_body == "hello file"
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    end

    test "includes content-disposition header when filename exists", %{
      conn: conn,
      rw_token: token
    } do
      {:ok, ref} = Files.upload("data", filename: "report.pdf", content_type: "application/pdf")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token.raw_token}")
        |> get("/api/files/#{URI.encode(ref["hash"])}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "report.pdf"
    end

    test "read-only token can download", %{conn: conn, ro_token: token} do
      {:ok, ref} = Files.upload("readable", content_type: "text/plain")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token.raw_token}")
        |> get("/api/files/#{URI.encode(ref["hash"])}")

      assert conn.status == 200
      assert conn.resp_body == "readable"
    end

    test "returns 401 without token", %{conn: conn} do
      conn = get(conn, "/api/files/sha256:fake")

      assert conn.status == 401
    end

    test "returns 401 with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer dust_tok_invalid")
        |> get("/api/files/sha256:fake")

      assert conn.status == 401
    end

    test "returns 404 for nonexistent hash", %{conn: conn, rw_token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token.raw_token}")
        |> get(
          "/api/files/#{URI.encode("sha256:0000000000000000000000000000000000000000000000000000000000000000")}"
        )

      assert conn.status == 404
    end
  end
end
