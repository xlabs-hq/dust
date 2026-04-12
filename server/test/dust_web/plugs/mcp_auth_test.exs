defmodule DustWeb.Plugs.MCPAuthTest do
  use DustWeb.ConnCase, async: true

  alias Dust.Accounts
  alias Dust.IntegrationHelpers
  alias Dust.MCP.Principal
  alias Dust.MCP.Sessions
  alias Dust.Stores
  alias DustWeb.Plugs.MCPAuth

  describe "MCPAuth plug" do
    test "401 + WWW-Authenticate when no token" do
      conn = build_conn() |> MCPAuth.call(MCPAuth.init([]))
      assert conn.status == 401
      assert conn.halted
      [www] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert www =~ "Bearer"
      assert www =~ "resource_metadata="
      assert www =~ "/.well-known/oauth-protected-resource"
    end

    test "401 when bearer token is unknown" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer not_a_real_token")
        |> MCPAuth.call(MCPAuth.init([]))

      assert conn.status == 401
      assert conn.halted
    end

    test "accepts legacy dust_tok_ store token and sets store_token principal" do
      %{token: raw_token_struct} =
        IntegrationHelpers.create_test_store(
          "mcpauth-#{System.unique_integer([:positive])}",
          "alpha"
        )

      raw = raw_token_struct.raw_token
      {:ok, authed} = Stores.authenticate_token(raw)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
        |> MCPAuth.call(MCPAuth.init([]))

      refute conn.halted
      principal = conn.assigns.mcp_principal
      assert %Principal{kind: :store_token} = principal
      assert principal.store_token.id == authed.id
      # Legacy assign retained for back-compat:
      assert conn.assigns.store_token.id == authed.id
    end

    test "accepts OAuth session token and sets user_session principal" do
      user = create_user()
      {raw, _session} = issue_test_token(user)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
        |> MCPAuth.call(MCPAuth.init([]))

      refute conn.halted
      principal = conn.assigns.mcp_principal
      assert %Principal{kind: :user_session} = principal
      assert principal.user.id == user.id
      # Legacy assign is NOT set for user-session principals.
      refute Map.has_key?(conn.assigns, :store_token)
    end

    test "rejects expired session token" do
      user = create_user()
      {raw, session} = issue_test_token(user)

      session
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Dust.Repo.update!()

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
        |> MCPAuth.call(MCPAuth.init([]))

      assert conn.status == 401
      assert conn.halted
    end
  end

  defp create_user do
    {:ok, user} =
      Accounts.create_user(%{
        email: "mcpauth_#{System.unique_integer([:positive])}@example.com"
      })

    user
  end

  # Inlined from Dust.MCP.SessionsTest.issue_test_token/1 so this file can run
  # standalone (mix test test/dust_web/plugs/mcp_auth_test.exs) without
  # depending on the sessions test file being loaded first.
  defp issue_test_token(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    {:ok, session} =
      Sessions.create_authorization_code(user, %{
        client_id: "client_test",
        client_redirect_uri: "http://localhost/cb",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    {:ok, raw, exchanged} =
      Sessions.exchange_code(session.session_id, %{
        code_verifier: verifier,
        client_id: "client_test",
        client_redirect_uri: "http://localhost/cb"
      })

    {raw, exchanged}
  end
end
