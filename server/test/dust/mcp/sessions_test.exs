defmodule Dust.MCP.SessionsTest do
  use Dust.DataCase, async: true

  alias Dust.Accounts
  alias Dust.MCP.Sessions

  describe "create_authorization_code/2" do
    test "creates a session with PKCE binding and 30-day expiry" do
      {:ok, user} =
        Accounts.create_user(%{
          email: "test_#{System.unique_integer([:positive])}@example.com"
        })

      attrs = %{
        client_id: "client_test",
        client_redirect_uri: "http://localhost:33418/cb",
        code_challenge: "abc123def456",
        code_challenge_method: "S256",
        remote_ip: "1.2.3.4",
        user_agent: "Claude Desktop/0.7"
      }

      assert {:ok, session} = Sessions.create_authorization_code(user, attrs)
      assert String.starts_with?(session.session_id, "mcp_")
      assert is_nil(session.access_token_hash)
      assert session.client_id == "client_test"
      assert session.client_redirect_uri == "http://localhost:33418/cb"
      assert session.code_challenge == "abc123def456"
      assert session.code_challenge_method == "S256"
      assert session.remote_ip == "1.2.3.4"
      assert DateTime.diff(session.expires_at, DateTime.utc_now(), :day) >= 29
    end
  end

  describe "hash_token/1" do
    test "is stable and lowercase hex" do
      assert Sessions.hash_token("hello") == Sessions.hash_token("hello")
      assert Sessions.hash_token("hello") =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
