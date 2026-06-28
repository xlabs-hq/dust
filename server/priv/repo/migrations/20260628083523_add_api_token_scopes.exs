defmodule Dust.Repo.Migrations.AddApiTokenScopes do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :token_prefix, :string, null: false, default: "dust_tok"
      add :token_last4, :string
      add :store_access_mode, :string, null: false, default: "selected"
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :revoked_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:api_tokens, [:organization_id])
    create index(:api_tokens, [:created_by_id])
    create index(:api_tokens, [:revoked_at])
    create unique_index(:api_tokens, [:token_hash])
    create unique_index(:api_tokens, [:id, :organization_id])

    create constraint(:api_tokens, :api_tokens_store_access_mode_check,
             check: "store_access_mode IN ('all', 'selected')"
           )

    create table(:api_token_scopes, primary_key: false) do
      add :token_id, references(:api_tokens, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_token_scopes, [:token_id, :scope])
    create index(:api_token_scopes, [:scope])

    create unique_index(:stores, [:id, :organization_id])

    create table(:api_token_store_grants, primary_key: false) do
      add :token_id, :binary_id, null: false
      add :organization_id, :binary_id, null: false
      add :store_id, :binary_id, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_token_store_grants, [:token_id, :store_id])
    create index(:api_token_store_grants, [:organization_id])
    create index(:api_token_store_grants, [:store_id])

    execute(
      """
      ALTER TABLE api_token_store_grants
      ADD CONSTRAINT api_token_store_grants_token_org_fkey
      FOREIGN KEY (token_id, organization_id)
      REFERENCES api_tokens(id, organization_id)
      ON DELETE CASCADE
      """,
      "ALTER TABLE api_token_store_grants DROP CONSTRAINT api_token_store_grants_token_org_fkey"
    )

    execute(
      """
      ALTER TABLE api_token_store_grants
      ADD CONSTRAINT api_token_store_grants_store_org_fkey
      FOREIGN KEY (store_id, organization_id)
      REFERENCES stores(id, organization_id)
      ON DELETE CASCADE
      """,
      "ALTER TABLE api_token_store_grants DROP CONSTRAINT api_token_store_grants_store_org_fkey"
    )

    execute(
      "ALTER TABLE api_tokens ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE api_tokens ALTER COLUMN id DROP DEFAULT"
    )

    execute(
      """
      INSERT INTO api_tokens (
        id,
        name,
        token_hash,
        token_prefix,
        store_access_mode,
        expires_at,
        last_used_at,
        organization_id,
        created_by_id,
        inserted_at,
        updated_at
      )
      SELECT
        t.id,
        t.name,
        t.token_hash,
        'dust_tok',
        'selected',
        t.expires_at,
        t.last_used_at,
        s.organization_id,
        t.created_by_id,
        t.inserted_at,
        t.updated_at
      FROM store_tokens t
      JOIN stores s ON s.id = t.store_id
      ON CONFLICT (token_hash) DO NOTHING
      """,
      "DELETE FROM api_tokens WHERE id IN (SELECT id FROM store_tokens)"
    )

    execute(
      """
      INSERT INTO api_token_scopes (token_id, scope, inserted_at, updated_at)
      SELECT t.id, scope, t.inserted_at, t.updated_at
      FROM store_tokens t
      CROSS JOIN LATERAL (
        SELECT unnest(ARRAY[
          'stores:read',
          'entries:read',
          'files:read',
          'webhooks:read',
          'audit:read'
        ]) AS scope
      ) read_scopes
      WHERE (t.permissions & 1) <> 0
      ON CONFLICT (token_id, scope) DO NOTHING
      """,
      """
      DELETE FROM api_token_scopes
      WHERE token_id IN (SELECT id FROM store_tokens)
        AND scope IN ('stores:read', 'entries:read', 'files:read', 'webhooks:read', 'audit:read')
      """
    )

    execute(
      """
      INSERT INTO api_token_scopes (token_id, scope, inserted_at, updated_at)
      SELECT t.id, scope, t.inserted_at, t.updated_at
      FROM store_tokens t
      CROSS JOIN LATERAL (
        SELECT unnest(ARRAY[
          'stores:clone',
          'entries:write',
          'files:write',
          'webhooks:write',
          'tokens:read',
          'tokens:write'
        ]) AS scope
      ) write_scopes
      WHERE (t.permissions & 2) <> 0
      ON CONFLICT (token_id, scope) DO NOTHING
      """,
      """
      DELETE FROM api_token_scopes
      WHERE token_id IN (SELECT id FROM store_tokens)
        AND scope IN ('stores:clone', 'entries:write', 'files:write', 'webhooks:write', 'tokens:read', 'tokens:write')
      """
    )

    execute(
      """
      INSERT INTO api_token_store_grants (
        token_id,
        organization_id,
        store_id,
        inserted_at,
        updated_at
      )
      SELECT
        t.id,
        s.organization_id,
        t.store_id,
        t.inserted_at,
        t.updated_at
      FROM store_tokens t
      JOIN stores s ON s.id = t.store_id
      ON CONFLICT (token_id, store_id) DO NOTHING
      """,
      "DELETE FROM api_token_store_grants WHERE token_id IN (SELECT id FROM store_tokens)"
    )
  end
end
