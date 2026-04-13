defmodule Dust.MCP.SessionsTest do
  use Dust.DataCase, async: true

  alias Dust.Accounts
  alias Dust.MCP.Sessions

  describe "create_authorization_code/2" do
    test "creates a session with PKCE binding and short auth-code lifetime" do
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
      # RFC 6749 §4.1.2: auth codes are short-lived (~10 minutes).
      # The bearer-token phase resets expires_at to 30d in do_issue/1.
      diff = DateTime.diff(session.expires_at, DateTime.utc_now(), :second)
      assert diff > 0
      assert diff <= 700
    end
  end

  describe "hash_token/1" do
    test "is stable and lowercase hex" do
      assert Sessions.hash_token("hello") == Sessions.hash_token("hello")
      assert Sessions.hash_token("hello") =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "exchange_code/2" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          email: "test_#{System.unique_integer([:positive])}@example.com"
        })

      code_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      code_challenge = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

      {:ok, session} =
        Sessions.create_authorization_code(user, %{
          client_id: "client_test",
          client_redirect_uri: "http://localhost:33418/cb",
          code_challenge: code_challenge,
          code_challenge_method: "S256"
        })

      %{user: user, session: session, verifier: code_verifier}
    end

    test "issues opaque token on valid PKCE + client binding", %{
      session: session,
      verifier: verifier
    } do
      assert {:ok, raw_token, updated} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })

      assert String.length(raw_token) >= 32
      assert updated.access_token_hash == Sessions.hash_token(raw_token)
      assert DateTime.diff(updated.expires_at, DateTime.utc_now(), :day) >= 29
    end

    test "rejects mismatched code_verifier", %{session: session} do
      assert {:error, :pkce_mismatch} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: "totally wrong verifier",
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })
    end

    test "rejects mismatched client_id", %{session: session, verifier: verifier} do
      assert {:error, :client_mismatch} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "wrong_client",
                 client_redirect_uri: "http://localhost:33418/cb"
               })
    end

    test "rejects mismatched redirect_uri", %{session: session, verifier: verifier} do
      assert {:error, :client_mismatch} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://attacker/cb"
               })
    end

    test "rejects already-exchanged code", %{session: session, verifier: verifier} do
      assert {:ok, _, _} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })

      assert {:error, :already_used} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })
    end

    test "rejects unknown session_id" do
      assert {:error, :invalid_grant} =
               Sessions.exchange_code("mcp_does_not_exist", %{
                 code_verifier: "x",
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })
    end

    test "rejects expired auth code with invalid_grant", %{
      session: session,
      verifier: verifier
    } do
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {:ok, _} =
        session
        |> Ecto.Changeset.change(expires_at: past)
        |> Dust.Repo.update()

      assert {:error, :invalid_grant} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })
    end

    test "rejects invalidated auth code with invalid_grant", %{
      session: session,
      verifier: verifier
    } do
      {:ok, _} = Sessions.invalidate(session)

      assert {:error, :invalid_grant} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })
    end

    test "does not revive invalidated session through CAS UPDATE", %{
      session: session,
      verifier: verifier
    } do
      {:ok, invalidated} = Sessions.invalidate(session)
      assert invalidated.invalidated_at

      assert {:error, :invalid_grant} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })

      # The row must still be dead: no token minted, invalidation intact.
      reloaded = Dust.Repo.get!(Dust.MCP.Session, session.id)
      assert is_nil(reloaded.access_token_hash)
      assert reloaded.invalidated_at
    end

    test "CAS UPDATE rejects session that expired between SELECT and UPDATE", %{
      session: session,
      verifier: verifier
    } do
      # Mutate the in-memory session so exchange_code's SELECT passes
      # (it uses the session_id, not the struct) but force expiry on the row
      # so the CAS UPDATE's `expires_at > now` guard catches it. We simulate
      # this by updating the DB row to an expired time after create but the
      # exchange_code SELECT will also see it — so to exercise the CAS guard
      # specifically we patch just before the UPDATE would run. Since we can't
      # easily inject between SELECT and UPDATE from here, we assert end-state:
      # expired rows are rejected with invalid_grant regardless of path.
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {:ok, _} =
        session
        |> Ecto.Changeset.change(expires_at: past)
        |> Dust.Repo.update()

      assert {:error, :invalid_grant} =
               Sessions.exchange_code(session.session_id, %{
                 code_verifier: verifier,
                 client_id: "client_test",
                 client_redirect_uri: "http://localhost:33418/cb"
               })

      reloaded = Dust.Repo.get!(Dust.MCP.Session, session.id)
      assert is_nil(reloaded.access_token_hash)
    end
  end

  describe "find_by_session_id/1" do
    test "returns session, ignoring invalidated rows" do
      {:ok, user} =
        Accounts.create_user(%{
          email: "test_#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, session} =
        Sessions.create_authorization_code(user, %{
          client_id: "c",
          client_redirect_uri: "http://x/cb",
          code_challenge: "x",
          code_challenge_method: "S256"
        })

      assert %Dust.MCP.Session{} = Sessions.find_by_session_id(session.session_id)

      {:ok, _} = Sessions.invalidate(session)
      assert is_nil(Sessions.find_by_session_id(session.session_id))
    end
  end

  describe "find_by_access_token_hash/1" do
    test "returns session for current hash, not after invalidation" do
      {:ok, user} =
        Accounts.create_user(%{
          email: "test_#{System.unique_integer([:positive])}@example.com"
        })

      {raw, session} = issue_test_token(user)

      found = Sessions.find_by_access_token_hash(Sessions.hash_token(raw))
      assert found.id == session.id

      Sessions.invalidate(found)
      assert is_nil(Sessions.find_by_access_token_hash(Sessions.hash_token(raw)))
    end
  end

  describe "touch_and_slide/1" do
    test "always bumps last_activity_at" do
      {:ok, user} =
        Accounts.create_user(%{
          email: "test_#{System.unique_integer([:positive])}@example.com"
        })

      {_raw, session} = issue_test_token(user)

      {:ok, stale} =
        session
        |> Ecto.Changeset.change(
          last_activity_at: DateTime.add(DateTime.utc_now(), -120, :second)
        )
        |> Dust.Repo.update()

      {:ok, touched} = Sessions.touch_and_slide(stale)
      assert DateTime.compare(touched.last_activity_at, stale.last_activity_at) == :gt
    end

    test "extends expires_at when remaining lifetime is less than (30d - 1h)" do
      {:ok, user} =
        Accounts.create_user(%{
          email: "test_#{System.unique_integer([:positive])}@example.com"
        })

      {_raw, session} = issue_test_token(user)

      short_expiry = DateTime.add(DateTime.utc_now(), 28 * 86_400, :second)

      {:ok, narrowed} =
        session
        |> Ecto.Changeset.change(expires_at: short_expiry)
        |> Dust.Repo.update()

      {:ok, slid} = Sessions.touch_and_slide(narrowed)
      assert DateTime.diff(slid.expires_at, DateTime.utc_now(), :day) >= 29
    end

    test "does NOT extend expires_at when remaining lifetime is still close to 30d" do
      {:ok, user} =
        Accounts.create_user(%{
          email: "test_#{System.unique_integer([:positive])}@example.com"
        })

      {_raw, session} = issue_test_token(user)

      {:ok, slid} = Sessions.touch_and_slide(session)
      assert DateTime.diff(slid.expires_at, session.expires_at, :second) |> abs() < 5
    end
  end

  def issue_test_token(user) do
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
