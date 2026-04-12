defmodule Dust.MCP.Session do
  use Dust.Schema

  alias Dust.Accounts.User

  schema "mcp_sessions" do
    field :session_id, :string
    field :access_token_hash, :string

    field :client_id, :string
    field :client_redirect_uri, :string
    field :code_challenge, :string
    field :code_challenge_method, :string

    field :client_name, :string
    field :client_version, :string
    field :remote_ip, :string
    field :user_agent, :string
    field :expires_at, :utc_datetime_usec
    field :last_activity_at, :utc_datetime_usec
    field :invalidated_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> Ecto.Changeset.cast(attrs, [
      :session_id,
      :access_token_hash,
      :user_id,
      :client_id,
      :client_redirect_uri,
      :code_challenge,
      :code_challenge_method,
      :client_name,
      :client_version,
      :remote_ip,
      :user_agent,
      :expires_at,
      :last_activity_at,
      :invalidated_at
    ])
    |> Ecto.Changeset.validate_required([:session_id, :user_id, :expires_at, :last_activity_at])
    |> Ecto.Changeset.unique_constraint(:session_id)
    |> Ecto.Changeset.unique_constraint(:access_token_hash)
  end
end
