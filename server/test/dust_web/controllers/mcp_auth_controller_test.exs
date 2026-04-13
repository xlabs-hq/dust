defmodule DustWeb.MCPAuthControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.MCP.Sessions
  alias Dust.WorkOSStub

  describe "GET /.well-known/oauth-protected-resource" do
    test "returns RFC 9728 metadata", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/oauth-protected-resource")
      body = json_response(conn, 200)
      assert is_binary(body["resource"])
      assert is_list(body["authorization_servers"])
      assert hd(body["authorization_servers"]) == body["resource"]
      assert "header" in body["bearer_methods_supported"]
    end
  end

  describe "GET /.well-known/oauth-authorization-server" do
    test "returns RFC 8414 metadata", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)
      assert is_binary(body["issuer"])
      assert body["authorization_endpoint"] =~ "/oauth/authorize"
      assert body["token_endpoint"] =~ "/oauth/token"
      assert body["registration_endpoint"] =~ "/register"
      assert "S256" in body["code_challenge_methods_supported"]
      assert "authorization_code" in body["grant_types_supported"]
    end
  end

  describe "POST /register" do
    test "returns the configured WorkOS MCP client_id", %{conn: conn} do
      payload = %{
        "client_name" => "Claude Desktop",
        "redirect_uris" => ["http://localhost:33418/oauth/callback"],
        "grant_types" => ["authorization_code"],
        "response_types" => ["code"]
      }

      conn = post(conn, ~p"/register", payload)
      body = json_response(conn, 200)

      assert is_binary(body["client_id"])
      assert body["client_id"] == Application.fetch_env!(:workos, :mcp_client_id)
      assert body["redirect_uris"] == payload["redirect_uris"]
      assert "authorization_code" in body["grant_types"]
    end
  end

  describe "GET /oauth/authorize" do
    test "stores client params in session and redirects to AuthKit", %{conn: conn} do
      Application.put_env(:dust, :authkit_base_url, "https://test.authkit.app")

      params = %{
        "response_type" => "code",
        "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
        "redirect_uri" => "http://localhost:33418/oauth/callback",
        "state" => "client_state_123",
        "code_challenge" => "abc123def456",
        "code_challenge_method" => "S256",
        "scope" => "profile email"
      }

      conn = get(conn, ~p"/oauth/authorize", params)
      assert redirected_to(conn, 302) =~ "https://test.authkit.app/oauth2/authorize"

      location = redirected_to(conn, 302)
      assert location =~ "code_challenge="

      assert location =~
               "redirect_uri=" <>
                 URI.encode_www_form(
                   "#{Application.fetch_env!(:dust, :mcp_base_url)}/oauth/callback"
                 )

      assert location =~ "state=oauth_flow_client_state_123"

      # Session must capture client params for the callback
      stored = get_session(conn, :oauth_params)
      assert stored.redirect_uri == "http://localhost:33418/oauth/callback"
      assert stored.code_challenge == "abc123def456"
      assert get_session(conn, :code_verifier)
    end

    test "400 on missing params", %{conn: conn} do
      conn = get(conn, ~p"/oauth/authorize", %{})
      assert json_response(conn, 400)["error"] == "invalid_request"
    end

    test "rejects arbitrary https redirect_uri (attacker case)", %{conn: conn} do
      Application.put_env(:dust, :mcp_redirect_uri_allowlist, [])

      params = %{
        "response_type" => "code",
        "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
        "redirect_uri" => "https://attacker.example/cb",
        "state" => "client_state_123",
        "code_challenge" => "abc123def456",
        "code_challenge_method" => "S256"
      }

      conn = get(conn, ~p"/oauth/authorize", params)
      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["error_description"] =~ "redirect_uri"
    end

    test "accepts http://127.0.0.1:PORT/cb loopback", %{conn: conn} do
      Application.put_env(:dust, :authkit_base_url, "https://test.authkit.app")

      params = %{
        "response_type" => "code",
        "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
        "redirect_uri" => "http://127.0.0.1:33418/cb",
        "state" => "s",
        "code_challenge" => "abc",
        "code_challenge_method" => "S256"
      }

      conn = get(conn, ~p"/oauth/authorize", params)
      assert redirected_to(conn, 302) =~ "/oauth2/authorize"
    end

    test "accepts http://localhost:PORT/cb loopback", %{conn: conn} do
      Application.put_env(:dust, :authkit_base_url, "https://test.authkit.app")

      params = %{
        "response_type" => "code",
        "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
        "redirect_uri" => "http://localhost:33418/cb",
        "state" => "s",
        "code_challenge" => "abc",
        "code_challenge_method" => "S256"
      }

      conn = get(conn, ~p"/oauth/authorize", params)
      assert redirected_to(conn, 302) =~ "/oauth2/authorize"
    end

    test "accepts allowlisted https URI when config is set", %{conn: conn} do
      Application.put_env(:dust, :authkit_base_url, "https://test.authkit.app")
      previous = Application.get_env(:dust, :mcp_redirect_uri_allowlist, [])
      Application.put_env(:dust, :mcp_redirect_uri_allowlist, ["https://claude.ai/api/mcp/"])
      on_exit(fn -> Application.put_env(:dust, :mcp_redirect_uri_allowlist, previous) end)

      params = %{
        "response_type" => "code",
        "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
        "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
        "state" => "s",
        "code_challenge" => "abc",
        "code_challenge_method" => "S256"
      }

      conn = get(conn, ~p"/oauth/authorize", params)
      assert redirected_to(conn, 302) =~ "/oauth2/authorize"
    end

    test "rejects non-loopback http redirect_uri", %{conn: conn} do
      params = %{
        "response_type" => "code",
        "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
        "redirect_uri" => "http://example.com/cb",
        "state" => "s",
        "code_challenge" => "abc",
        "code_challenge_method" => "S256"
      }

      conn = get(conn, ~p"/oauth/authorize", params)
      assert json_response(conn, 400)["error"] == "invalid_request"
    end
  end

  describe "GET /oauth/callback" do
    setup do
      workos_user =
        struct!(WorkOS.UserManagement.User, %{
          id: "user_workos_#{System.unique_integer([:positive])}",
          email: "callback-#{System.unique_integer([:positive])}@example.com",
          first_name: "Call",
          last_name: "Back",
          email_verified: true,
          updated_at: "2026-01-01T00:00:00.000Z",
          created_at: "2026-01-01T00:00:00.000Z"
        })

      WorkOSStub.set_response(%{user: workos_user})
      %{workos_user: workos_user}
    end

    test "creates session, redirects to client redirect_uri with code=session_id",
         %{conn: conn, workos_user: workos_user} do
      conn =
        conn
        |> init_test_session(%{
          oauth_params: %{
            client_id: "client_dev",
            redirect_uri: "http://localhost:33418/oauth/callback",
            state: "oauth_flow_state123",
            code_challenge: "client_challenge",
            code_challenge_method: "S256",
            scope: ""
          },
          code_verifier: "upstream_verifier"
        })
        |> get(~p"/oauth/callback?code=workos_code&state=oauth_flow_state123")

      location = redirected_to(conn, 302)
      assert location =~ "http://localhost:33418/oauth/callback"
      assert location =~ "code=mcp_"
      assert location =~ "state=state123"

      code =
        location
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()
        |> Map.get("code")

      session = Sessions.find_by_session_id(code)
      assert session
      assert session.user.workos_id == workos_user.id
      assert is_nil(session.access_token_hash)
      assert session.code_challenge == "client_challenge"
      assert session.code_challenge_method == "S256"
      assert session.client_id == "client_dev"
      assert session.client_redirect_uri == "http://localhost:33418/oauth/callback"
    end

    test "echoes client state verbatim even when it starts with oauth_flow_",
         %{conn: conn, workos_user: _workos_user} do
      # Client legitimately sent state="oauth_flow_foo". We stored
      # "oauth_flow_oauth_flow_foo"; the callback must strip exactly one prefix
      # and return "oauth_flow_foo" back to the client, not "foo".
      conn =
        conn
        |> init_test_session(%{
          oauth_params: %{
            client_id: "client_dev",
            redirect_uri: "http://localhost:33418/oauth/callback",
            state: "oauth_flow_oauth_flow_foo",
            code_challenge: "client_challenge",
            code_challenge_method: "S256",
            scope: ""
          },
          code_verifier: "upstream_verifier"
        })
        |> get(~p"/oauth/callback?code=workos_code&state=oauth_flow_oauth_flow_foo")

      location = redirected_to(conn, 302)

      echoed_state =
        location
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()
        |> Map.get("state")

      assert echoed_state == "oauth_flow_foo"
    end

    test "invokes WorkOS client with MCP client_id, upstream code_verifier, and authorization code",
         %{conn: conn} do
      _ =
        conn
        |> init_test_session(%{
          oauth_params: %{
            client_id: "client_dev",
            redirect_uri: "http://localhost:33418/oauth/callback",
            state: "oauth_flow_state456",
            code_challenge: "client_challenge",
            code_challenge_method: "S256",
            scope: ""
          },
          code_verifier: "upstream_verifier_abc"
        })
        |> get(~p"/oauth/callback?code=workos_code_xyz&state=oauth_flow_state456")

      call = WorkOSStub.get_last_call()
      assert call.code == "workos_code_xyz"
      assert call.code_verifier == "upstream_verifier_abc"
      assert call.client_id == Application.fetch_env!(:workos, :mcp_client_id)

      assert call.redirect_uri ==
               "#{Application.fetch_env!(:dust, :mcp_base_url)}/oauth/callback"
    end
  end

  describe "POST /oauth/token" do
    setup do
      {:ok, user} =
        Dust.Accounts.create_user(%{
          email: "token-#{System.unique_integer([:positive])}@example.com"
        })

      verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      {:ok, session} =
        Dust.MCP.Sessions.create_authorization_code(user, %{
          client_id: "client_test",
          client_redirect_uri: "http://localhost:33418/cb",
          code_challenge: challenge,
          code_challenge_method: "S256"
        })

      %{user: user, session: session, verifier: verifier}
    end

    test "exchanges session_id for opaque bearer token on valid PKCE", %{
      conn: conn,
      session: session,
      verifier: verifier
    } do
      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => session.session_id,
          "code_verifier" => verifier,
          "client_id" => "client_test",
          "redirect_uri" => "http://localhost:33418/cb"
        })

      body = json_response(conn, 200)
      assert is_binary(body["access_token"])
      assert body["token_type"] == "Bearer"
      assert body["expires_in"] > 86_400
    end

    test "rejects mismatched code_verifier with invalid_grant", %{conn: conn, session: session} do
      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => session.session_id,
          "code_verifier" => "wrong",
          "client_id" => "client_test",
          "redirect_uri" => "http://localhost:33418/cb"
        })

      assert json_response(conn, 400)["error"] == "invalid_grant"
    end

    test "rejects already-consumed session_id", %{
      conn: conn,
      session: session,
      verifier: verifier
    } do
      params = %{
        "grant_type" => "authorization_code",
        "code" => session.session_id,
        "code_verifier" => verifier,
        "client_id" => "client_test",
        "redirect_uri" => "http://localhost:33418/cb"
      }

      _ = post(conn, ~p"/oauth/token", params)
      second = post(build_conn(), ~p"/oauth/token", params)

      assert json_response(second, 400)["error"] == "invalid_grant"
    end

    test "rejects unsupported grant_type" do
      conn = post(build_conn(), ~p"/oauth/token", %{"grant_type" => "client_credentials"})
      assert json_response(conn, 400)["error"] == "unsupported_grant_type"
    end
  end
end
