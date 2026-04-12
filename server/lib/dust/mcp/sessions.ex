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
end
