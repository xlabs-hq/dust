defmodule Dust.Repo.Migrations.CreateStoreWebhooks do
  use Ecto.Migration

  def change do
    create table(:store_webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :secret, :text, null: false
      add :active, :boolean, null: false, default: true
      add :last_delivered_seq, :integer, null: false, default: 0
      add :failure_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:store_webhooks, [:store_id])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :webhook_id, references(:store_webhooks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :store_seq, :integer, null: false
      add :status_code, :integer
      add :response_ms, :integer
      add :error, :text
      add :attempted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:webhook_deliveries, [:webhook_id])
    create index(:webhook_deliveries, [:attempted_at])

    execute(
      "ALTER TABLE store_webhooks ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE store_webhooks ALTER COLUMN id DROP DEFAULT"
    )

    execute(
      "ALTER TABLE webhook_deliveries ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE webhook_deliveries ALTER COLUMN id DROP DEFAULT"
    )
  end
end
