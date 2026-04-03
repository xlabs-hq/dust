defmodule Dust.Webhooks.CatchUpWorker do
  use Oban.Worker, queue: :webhooks

  alias Dust.{Sync, Webhooks}

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
    %{
      "event" => "entry.changed",
      "store" => "#{store.organization.slug}/#{store.name}",
      "store_seq" => op.store_seq,
      "op" => to_string(op.op),
      "path" => op.path,
      "value" => op.value,
      "device_id" => op.device_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
