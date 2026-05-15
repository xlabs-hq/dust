defmodule DustWeb.MCPAuthControllerTest do
  use DustWeb.ConnCase, async: false

  import Dust.AccountsFixtures

  alias Dust.MCP.Sessions
  alias DustWeb.MCPAuth.FlowToken

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

  describe "GET /oauth/authorize (embedded flow)" do
    setup do
      %{
        params: %{
          "response_type" => "code",
          "client_id" => "client_123",
          "redirect_uri" => "https://app.example/cb",
          "state" => "client-state",
          "code_challenge" => "abc",
          "code_challenge_method" => "S256"
        }
      }
    end

    test "redirects unauthenticated user to /auth/login with return_to", %{
      conn: conn,
      params: params
    } do
      conn = put_allowlisted_redirect(conn, params["redirect_uri"])

      conn = get(conn, ~p"/oauth/authorize?#{params}")

      assert redirected_to(conn) =~ "/auth/login"
      assert get_session(conn, :user_return_to) =~ "/oauth/authorize/continue?flow="
    end

    test "redirects signed-in user straight to /oauth/authorize/continue", %{
      conn: conn,
      params: params
    } do
      user = user_fixture()

      conn =
        conn
        |> put_allowlisted_redirect(params["redirect_uri"])
        |> log_in_user(user)
        |> get(~p"/oauth/authorize?#{params}")

      assert redirected_to(conn) =~ "/oauth/authorize/continue?flow="
      refute get_session(conn, :user_return_to)
    end

    test "rejects code_challenge_method=plain", %{conn: conn, params: params} do
      conn = put_allowlisted_redirect(conn, params["redirect_uri"])
      params = Map.put(params, "code_challenge_method", "plain")
      conn = get(conn, ~p"/oauth/authorize?#{params}")
      assert json_response(conn, 400)["error"] == "invalid_request"
    end

    test "400 on missing params", %{conn: conn} do
      conn = get(conn, ~p"/oauth/authorize", %{})
      assert json_response(conn, 400)["error"] == "invalid_request"
    end

    test "rejects arbitrary https redirect_uri (attacker case)", %{conn: conn, params: params} do
      Application.put_env(:dust, :mcp_redirect_uri_allowlist, [])

      params = Map.put(params, "redirect_uri", "https://attacker.example/cb")

      conn = get(conn, ~p"/oauth/authorize", params)
      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["error_description"] =~ "redirect_uri"
    end

    test "accepts http://127.0.0.1:PORT/cb loopback", %{conn: conn, params: params} do
      params = Map.put(params, "redirect_uri", "http://127.0.0.1:33418/cb")

      conn = get(conn, ~p"/oauth/authorize", params)
      assert redirected_to(conn) =~ "/auth/login"
    end

    test "accepts http://localhost:PORT/cb loopback", %{conn: conn, params: params} do
      params = Map.put(params, "redirect_uri", "http://localhost:33418/cb")

      conn = get(conn, ~p"/oauth/authorize", params)
      assert redirected_to(conn) =~ "/auth/login"
    end

    test "rejects non-loopback http redirect_uri", %{conn: conn, params: params} do
      params = Map.put(params, "redirect_uri", "http://example.com/cb")

      conn = get(conn, ~p"/oauth/authorize", params)
      assert json_response(conn, 400)["error"] == "invalid_request"
    end
  end

  describe "GET /oauth/authorize/continue" do
    setup do
      user = user_fixture()

      oauth_params = %{
        client_id: "client_123",
        redirect_uri: "https://app.example/cb",
        state: "client-state",
        code_challenge: "abc",
        code_challenge_method: "S256",
        scope: ""
      }

      %{user: user, oauth_params: oauth_params}
    end

    test "renders consent inertia page when signed in with valid flow token", ctx do
      %{conn: conn, user: user, oauth_params: oauth_params} = ctx
      token = FlowToken.encode(oauth_params)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize/continue?flow=#{token}")

      assert html_response(conn, 200) =~ "OAuth/Authorize"
      assert response(conn, 200) =~ oauth_params.client_id
      assert response(conn, 200) =~ user.email
    end

    test "redirects to /auth/login when not signed in", ctx do
      %{conn: conn, oauth_params: oauth_params} = ctx
      token = FlowToken.encode(oauth_params)

      conn =
        conn
        |> get(~p"/oauth/authorize/continue?flow=#{token}")

      assert redirected_to(conn) =~ "/auth/login"
    end

    test "rejects invalid flow token with 400", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize/continue?flow=bogus")

      assert json_response(conn, 400)["error"] == "invalid_request"
    end
  end

  describe "POST /oauth/authorize/approve" do
    setup do
      user = user_fixture()

      oauth_params = %{
        client_id: "client_123",
        redirect_uri: "https://app.example/cb",
        state: "client-state",
        code_challenge: "abc",
        code_challenge_method: "S256",
        scope: ""
      }

      %{user: user, oauth_params: oauth_params}
    end

    test "allow mints code and redirects to client_redirect_uri", ctx do
      %{conn: conn, user: user, oauth_params: oauth_params} = ctx
      token = FlowToken.encode(oauth_params)

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize/approve", %{"flow" => token, "action" => "allow"})

      location = redirected_to(conn)
      assert location =~ "https://app.example/cb?"
      assert location =~ "code="
      assert location =~ "state=client-state"

      code = URI.parse(location).query |> URI.decode_query() |> Map.fetch!("code")
      session = Sessions.find_by_session_id(code)
      assert %Dust.MCP.Session{user_id: user_id} = session
      assert user_id == user.id
    end

    test "deny redirects with error=access_denied", ctx do
      %{conn: conn, user: user, oauth_params: oauth_params} = ctx
      token = FlowToken.encode(oauth_params)

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/authorize/approve", %{"flow" => token, "action" => "deny"})

      location = redirected_to(conn)
      assert location =~ "error=access_denied"
      assert location =~ "state=client-state"
    end

    test "requires signed-in user", ctx do
      %{conn: conn, oauth_params: oauth_params} = ctx
      token = FlowToken.encode(oauth_params)

      conn = post(conn, ~p"/oauth/authorize/approve", %{"flow" => token, "action" => "allow"})
      assert redirected_to(conn) =~ "/auth/login"
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
