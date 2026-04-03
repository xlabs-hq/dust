defmodule Dust.Webhooks.DeliveryWorker do
  use Oban.Worker, queue: :webhooks, max_attempts: 5

  alias Dust.Webhooks

  @timeout 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_id" => webhook_id, "event" => event}}) do
    webhook = Webhooks.get_webhook!(webhook_id)

    if not webhook.active do
      :ok
    else
      body = Jason.encode!(event)
      signature = sign(body, webhook.secret)
      start_time = System.monotonic_time(:millisecond)

      case Req.post(webhook.url,
             body: body,
             headers: [
               {"content-type", "application/json"},
               {"x-dust-signature", "sha256=#{signature}"}
             ],
             receive_timeout: @timeout,
             retry: false
           ) do
        {:ok, %{status: status}} when status >= 200 and status < 300 ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          store_seq = event["store_seq"]

          Webhooks.record_delivery(webhook_id, %{
            store_seq: store_seq || 0,
            status_code: status,
            response_ms: elapsed
          })

          if store_seq, do: Webhooks.mark_delivered(webhook_id, store_seq)
          :ok

        {:ok, %{status: status}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          store_seq = event["store_seq"]

          Webhooks.record_delivery(webhook_id, %{
            store_seq: store_seq || 0,
            status_code: status,
            response_ms: elapsed
          })

          Webhooks.mark_failed(webhook_id)
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          store_seq = event["store_seq"]

          Webhooks.record_delivery(webhook_id, %{
            store_seq: store_seq || 0,
            error: inspect(reason)
          })

          Webhooks.mark_failed(webhook_id)
          {:error, inspect(reason)}
      end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    [60, 300, 1800, 7200, 43200]
    |> Enum.at(attempt - 1, 43200)
  end

  def sign(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end
end
