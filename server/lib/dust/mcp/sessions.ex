defmodule Dust.MCP.Sessions do
  @moduledoc """
  Context for MCP OAuth sessions.

  A session row plays two roles in its lifetime:

    1. **Authorization code phase** (`access_token_hash IS NULL`) — created by
       `create_authorization_code/2` at `/oauth/callback` time. The PKCE
       challenge, client_id, and client redirect_uri are persisted for later
       back-channel validation.

    2. **Bearer token phase** (`access_token_hash` set) — entered by
       `exchange_code/2` at `/oauth/token` time, which validates PKCE,
       generates an opaque token, hashes it, and updates the row in a single
       transaction guarded by `WHERE access_token_hash IS NULL`.
  """

  import Ecto.Query

  alias Dust.MCP.Session
  alias Dust.Repo

  @token_lifetime_seconds 30 * 86_400
  @slide_threshold_seconds 60 * 60

  def create_authorization_code(user, attrs) do
    now = DateTime.utc_now()

    base = %{
      session_id: "mcp_" <> Ecto.UUID.generate(),
      user_id: user.id,
      expires_at: DateTime.add(now, @token_lifetime_seconds, :second),
      last_activity_at: now
    }

    %Session{}
    |> Session.changeset(Map.merge(base, attrs))
    |> Repo.insert()
  end

  def hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  def find_by_session_id(session_id) when is_binary(session_id) do
    from(s in Session,
      where: s.session_id == ^session_id and is_nil(s.invalidated_at),
      preload: [:user]
    )
    |> Repo.one()
  end

  def find_by_access_token_hash(hash) when is_binary(hash) do
    from(s in Session,
      where: s.access_token_hash == ^hash and is_nil(s.invalidated_at),
      preload: [:user]
    )
    |> Repo.one()
  end

  def invalidate(%Session{} = session) do
    session
    |> Session.changeset(%{invalidated_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def touch_and_slide(%Session{} = session) do
    now = DateTime.utc_now()
    remaining = DateTime.diff(session.expires_at, now, :second)
    full_lifetime = @token_lifetime_seconds
    slide? = remaining < full_lifetime - @slide_threshold_seconds

    attrs =
      if slide? do
        %{
          last_activity_at: now,
          expires_at: DateTime.add(now, full_lifetime, :second)
        }
      else
        %{last_activity_at: now}
      end

    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  def exchange_code(session_id, %{
        code_verifier: verifier,
        client_id: client_id,
        client_redirect_uri: redirect_uri
      })
      when is_binary(session_id) do
    case Repo.get_by(Session, session_id: session_id) do
      nil ->
        {:error, :invalid_grant}

      %Session{access_token_hash: hash} when not is_nil(hash) ->
        {:error, :already_used}

      %Session{} = session ->
        cond do
          session.client_id != client_id ->
            {:error, :client_mismatch}

          session.client_redirect_uri != redirect_uri ->
            {:error, :client_mismatch}

          not pkce_matches?(session, verifier) ->
            {:error, :pkce_mismatch}

          true ->
            do_issue(session)
        end
    end
  end

  defp pkce_matches?(
         %Session{code_challenge: challenge, code_challenge_method: "S256"},
         verifier
       )
       when is_binary(challenge) and is_binary(verifier) do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  defp pkce_matches?(_session, _verifier), do: false

  defp do_issue(%Session{} = session) do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    hash = hash_token(raw_token)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @token_lifetime_seconds, :second)

    # Atomic check-and-set: only update if the row is still in auth-code phase.
    query =
      from(s in Session,
        where: s.id == ^session.id and is_nil(s.access_token_hash),
        update: [
          set: [
            access_token_hash: ^hash,
            expires_at: ^expires_at,
            last_activity_at: ^now,
            updated_at: ^now
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, _} ->
        updated = Repo.get!(Session, session.id) |> Repo.preload(:user)
        {:ok, raw_token, updated}

      {0, _} ->
        # Someone exchanged this code between our SELECT and UPDATE.
        {:error, :already_used}
    end
  end
end
