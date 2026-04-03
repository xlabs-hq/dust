defmodule Dust.Webhooks.DeliveryLog do
  use Dust.Schema

  schema "webhook_deliveries" do
    field :store_seq, :integer
    field :status_code, :integer
    field :response_ms, :integer
    field :error, :string
    field :attempted_at, :utc_datetime_usec

    belongs_to :webhook, Dust.Webhooks.Webhook
  end
end
