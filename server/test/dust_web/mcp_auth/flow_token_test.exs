defmodule DustWeb.MCPAuth.FlowTokenTest do
  use ExUnit.Case, async: true

  alias DustWeb.MCPAuth.FlowToken

  describe "encode/1 + verify/1" do
    test "encode then verify returns the original oauth_params" do
      params = %{
        client_id: "client_123",
        redirect_uri: "https://app.example/cb",
        state: "abc",
        code_challenge: "challenge",
        code_challenge_method: "S256",
        scope: ""
      }

      token = FlowToken.encode(params)
      assert {:ok, ^params} = FlowToken.verify(token)
    end

    test "verify rejects tampered token" do
      assert {:error, _} = FlowToken.verify("not-a-real-token")
    end
  end
end
