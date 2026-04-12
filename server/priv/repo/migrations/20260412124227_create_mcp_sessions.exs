defmodule Dust.Repo.Migrations.CreateMcpSessions do
  use Ecto.Migration

  def change do
    create table(:mcp_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :access_token_hash, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # OAuth + PKCE binding (set at /oauth/callback, validated at /oauth/token)
      add :client_id, :string
      add :client_redirect_uri, :string
      add :code_challenge, :string
      add :code_challenge_method, :string

      add :client_name, :string
      add :client_version, :string
      add :remote_ip, :string
      add :user_agent, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :last_activity_at, :utc_datetime_usec, null: false
      add :invalidated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_sessions, [:session_id])
    create unique_index(:mcp_sessions, [:access_token_hash])
    create index(:mcp_sessions, [:user_id])
    create index(:mcp_sessions, [:expires_at])
  end
end
