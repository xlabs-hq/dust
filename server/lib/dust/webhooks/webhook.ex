defmodule Dust.Webhooks.Webhook do
  use Dust.Schema

  schema "store_webhooks" do
    field :url, :string
    field :secret, :string
    field :active, :boolean, default: true
    field :last_delivered_seq, :integer, default: 0
    field :failure_count, :integer, default: 0

    belongs_to :store, Dust.Stores.Store

    has_many :deliveries, Dust.Webhooks.DeliveryLog

    timestamps()
  end

  def changeset(webhook, attrs) do
    webhook
    |> Ecto.Changeset.cast(attrs, [:url, :store_id])
    |> Ecto.Changeset.validate_required([:url, :store_id])
    |> Ecto.Changeset.validate_format(:url, ~r/^https?:\/\//)
  end
end
