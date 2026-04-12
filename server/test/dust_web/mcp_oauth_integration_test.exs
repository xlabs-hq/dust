defmodule DustWeb.MCPOAuthIntegrationTest do
  use DustWeb.ConnCase, async: false

  alias Dust.Accounts
  alias Dust.MCP.Principal
  alias Dust.MCP.Sessions
  alias DustWeb.Plugs.MCPAuth

  test "full OAuth + tool call happy path stops at the auth plug" do
    # 0. Local user (skip WorkOS find_or_create — we're stubbing the round-trip)
    {:ok, user} =
      Accounts.create_user(%{
        email: "mcp-oauth-#{System.unique_integer([:positive])}@example.test",
        first_name: "Integration",
        last_name: "Tester"
      })

    # 1. Discovery: protected-resource metadata
    discovery_conn = build_conn() |> get(~p"/.well-known/oauth-protected-resource")
    discovery_body = json_response(discovery_conn, 200)
    assert is_list(discovery_body["authorization_servers"])
    assert hd(discovery_body["authorization_servers"]) == discovery_body["resource"]

    # 2. DCR: register a client
    register_conn =
      build_conn()
      |> post(~p"/register", %{
        "client_name" => "integration-test",
        "redirect_uris" => ["http://localhost/cb"]
      })

    register_body = json_response(register_conn, 200)
    assert is_binary(register_body["client_id"])
    client_id = register_body["client_id"]
    redirect_uri = "http://localhost/cb"

    # 3. Skip the WorkOS round-trip — directly create an authorization code
    #    as if /oauth/callback had run after AuthKit redirected back.
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    {:ok, session} =
      Sessions.create_authorization_code(user, %{
        client_id: client_id,
        client_redirect_uri: redirect_uri,
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    # 4. Token exchange: POST /oauth/token returns an opaque access_token
    token_conn =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => session.session_id,
        "code_verifier" => verifier,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri
      })

    token_body = json_response(token_conn, 200)
    assert %{"access_token" => raw_token, "token_type" => "Bearer"} = token_body
    assert is_binary(raw_token)
    assert token_body["expires_in"] > 0

    # 5. Drive the auth plug directly with the issued token. We stop at the
    #    auth plug rather than threading through the full GenMCP transport —
    #    that's exercised by the existing tool tests, and the goal here is to
    #    prove the OAuth-issued token authenticates the principal correctly.
    authed_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> raw_token)
      |> MCPAuth.call(MCPAuth.init([]))

    refute authed_conn.halted

    assert %Principal{kind: :user_session, user: principal_user, session: principal_session} =
             authed_conn.assigns[:mcp_principal]

    assert principal_user.id == user.id
    assert principal_session.session_id == session.session_id
  end
end
