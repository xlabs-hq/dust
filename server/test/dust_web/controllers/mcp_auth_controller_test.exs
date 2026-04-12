defmodule DustWeb.MCPAuthControllerTest do
  use DustWeb.ConnCase, async: true

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
end
