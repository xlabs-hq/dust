defmodule Dust.Webhooks.CatchUpWorker do
  use Oban.Worker, queue: :webhooks

  alias Dust.{Sync, Webhooks}
  alias Dust.Sync.ValueCodec

  @impl Oban.Worker
  def perform(_job) do
    webhooks = Webhooks.webhooks_needing_catchup()

    Enum.each(webhooks, fn webhook ->
      ops = Sync.get_ops_since(webhook.store_id, webhook.last_delivered_seq)

      Enum.each(ops, fn op ->
        event = build_event(webhook.store, op)

        %{webhook_id: webhook.id, event: event}
        |> Dust.Webhooks.DeliveryWorker.new()
        |> Oban.insert()
      end)
    end)

    :ok
  end

  defp build_event(store, op) do
    value = materialize_value(store.id, op)

    %{
      "event" => "entry.changed",
      "store" => "#{store.organization.slug}/#{store.name}",
      "store_seq" => op.store_seq,
      "op" => to_string(op.op),
      "path" => op.path,
      "value" => value,
      "device_id" => op.device_id,
      "timestamp" => op[:inserted_at] || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # For increment/add/remove ops, the stored value is a delta — read the current
  # materialized entry value instead. For set/delete/merge, unwrap the stored value.
  defp materialize_value(store_id, %{op: op} = op_data) when op in [:increment, :add, :remove] do
    case Sync.get_entry(store_id, op_data.path) do
      nil -> ValueCodec.unwrap(op_data.value)
      entry -> entry.value
    end
  end

  defp materialize_value(_store_id, op) do
    ValueCodec.unwrap(op.value)
  end
end
