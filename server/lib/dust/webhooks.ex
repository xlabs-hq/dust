defmodule Dust.Webhooks do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Webhooks.{Webhook, DeliveryLog}

  def create_webhook(store, attrs) do
    secret = generate_secret()

    %Webhook{}
    |> Webhook.changeset(Map.put(attrs, :store_id, store.id))
    |> Ecto.Changeset.put_change(:secret, secret)
    |> Repo.insert()
  end

  def list_webhooks(store) do
    from(w in Webhook, where: w.store_id == ^store.id, order_by: [desc: :inserted_at])
    |> Repo.all()
  end

  def get_webhook!(id), do: Repo.get!(Webhook, id)

  def get_webhook(webhook_id, store_id) do
    case Repo.get_by(Webhook, id: webhook_id, store_id: store_id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  def delete_webhook(webhook_id, store_id) do
    case Repo.get_by(Webhook, id: webhook_id, store_id: store_id) do
      nil ->
        {:error, :not_found}

      webhook ->
        Repo.delete(webhook)
        :ok
    end
  end

  def active_webhooks_for_store(store_id) do
    from(w in Webhook, where: w.store_id == ^store_id and w.active == true)
    |> Repo.all()
  end

  def mark_delivered(webhook_id, store_seq) do
    from(w in Webhook, where: w.id == ^webhook_id)
    |> Repo.update_all(set: [last_delivered_seq: store_seq, failure_count: 0])
  end

  def mark_failed(webhook_id) do
    from(w in Webhook, where: w.id == ^webhook_id)
    |> Repo.update_all(inc: [failure_count: 1])

    from(w in Webhook, where: w.id == ^webhook_id and w.failure_count >= 5)
    |> Repo.update_all(set: [active: false])
  end

  def reactivate(webhook_id) do
    from(w in Webhook, where: w.id == ^webhook_id)
    |> Repo.update_all(set: [active: true, failure_count: 0])
  end

  def record_delivery(webhook_id, attrs) do
    %DeliveryLog{
      webhook_id: webhook_id,
      store_seq: attrs.store_seq,
      status_code: attrs[:status_code],
      response_ms: attrs[:response_ms],
      error: attrs[:error],
      attempted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
    |> Repo.insert()
  end

  def list_deliveries(webhook_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(d in DeliveryLog,
      where: d.webhook_id == ^webhook_id,
      order_by: [desc: :attempted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def webhooks_needing_catchup do
    from(w in Webhook,
      join: s in assoc(w, :store),
      where: w.active == true and w.last_delivered_seq < s.current_seq,
      preload: [store: {s, :organization}]
    )
    |> Repo.all()
  end

  def enqueue_deliveries(store_id, event) do
    webhooks = active_webhooks_for_store(store_id)

    Enum.each(webhooks, fn webhook ->
      %{webhook_id: webhook.id, event: event}
      |> Dust.Webhooks.DeliveryWorker.new()
      |> Oban.insert()
    end)
  end

  defp generate_secret do
    "whsec_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end
end
