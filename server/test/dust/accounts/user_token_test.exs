defmodule Dust.Accounts.UserTokenTest do
  use Dust.DataCase, async: true

  alias Dust.Accounts
  alias Dust.Accounts.UserToken

  defp create_user(_context) do
    {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
    %{user: user}
  end

  describe "generate_user_session_token/1" do
    setup [:create_user]

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert is_binary(token)
      assert byte_size(token) == 32

      # Token is stored in the database
      assert Repo.get_by(UserToken, context: "session", user_id: user.id)
    end

    test "generates unique tokens for each call", %{user: user} do
      token1 = Accounts.generate_user_session_token(user)
      token2 = Accounts.generate_user_session_token(user)
      refute token1 == token2
    end
  end

  describe "get_user_by_session_token/1" do
    setup [:create_user]

    test "returns user for a valid token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert {found_user, inserted_at} = Accounts.get_user_by_session_token(token)
      assert found_user.id == user.id
      assert %DateTime{} = inserted_at
    end

    test "returns nil for an invalid token" do
      assert Accounts.get_user_by_session_token(:crypto.strong_rand_bytes(32)) == nil
    end

    test "returns nil for an expired token", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      # Manually expire the token
      {1, nil} =
        Repo.update_all(
          UserToken.by_token_and_context_query(token, "session"),
          set: [inserted_at: ~U[2020-01-01 00:00:00.000000Z]]
        )

      assert Accounts.get_user_by_session_token(token) == nil
    end
  end

  describe "delete_user_session_token/1" do
    setup [:create_user]

    test "deletes the token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token)
      assert :ok = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end
  end
end
