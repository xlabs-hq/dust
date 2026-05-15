defmodule DustWeb.Integration.MCPOAuthEmbeddedTest do
  use DustWeb.ConnCase, async: false

  import Dust.AccountsFixtures

  test "full embedded MCP OAuth flow", %{conn: conn} do
    user = user_fixture()
    redirect_uri = "https://app.example/cb"
    client_id = "client_123"

    code_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    code_challenge =
      :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

    # 1. /oauth/authorize — unauthenticated → redirects to /auth/login
    params = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "state" => "client-state",
      "code_challenge" => code_challenge,
      "code_challenge_method" => "S256"
    }

    conn = put_allowlisted_redirect(conn, redirect_uri)
    conn = get(conn, ~p"/oauth/authorize?#{params}")
    assert redirected_to(conn) =~ "/auth/login"
    return_to = get_session(conn, :user_return_to)
    assert return_to =~ "/oauth/authorize/continue?flow="

    # 2. Sign in (recycle conn since the previous one has been sent)
    conn = log_in_user(recycle(conn), user)

    # 3. Follow return_to → consent page
    conn = get(conn, return_to)
    assert html_response(conn, 200) =~ "OAuth/Authorize"

    # Extract flow token from the URL we know
    flow_token = URI.parse(return_to).query |> URI.decode_query() |> Map.fetch!("flow")

    # 4. Approve
    conn = post(conn, ~p"/oauth/authorize/approve", %{"flow" => flow_token, "action" => "allow"})
    location = redirected_to(conn)
    assert location =~ "https://app.example/cb?"
    code = URI.parse(location).query |> URI.decode_query() |> Map.fetch!("code")

    # 5. Exchange code at /oauth/token (fresh conn = back-channel POST from MCP client)
    conn =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => code_verifier,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri
      })

    body = json_response(conn, 200)
    assert body["access_token"]
    assert body["token_type"] == "Bearer"

    # 6. Reusing the code fails
    conn =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => code_verifier,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri
      })

    assert json_response(conn, 400)["error"] == "invalid_grant"
  end
end
