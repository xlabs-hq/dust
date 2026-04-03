defmodule Dust.Webhooks.CatchUpWorkerTest do
  use Dust.DataCase, async: false
  use Oban.Testing, repo: Dust.Repo

  alias Dust.{Accounts, Stores, Sync, Webhooks}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "catchup@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "catchtest"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store}
  end

  test "enqueues delivery jobs for webhooks behind current_seq", %{store: store} do
    # Write data BEFORE creating webhook so Sync.write doesn't enqueue for it
    Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
    Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})

    {:ok, _webhook} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

    # Run catch-up worker — webhook was created after writes, so it's behind
    :ok = perform_job(Dust.Webhooks.CatchUpWorker, %{})

    # Should have enqueued 2 delivery jobs (only from catch-up, not from Sync.write)
    assert length(all_enqueued(worker: Dust.Webhooks.DeliveryWorker)) == 2
  end

  test "skips webhooks that are caught up", %{store: store} do
    # Write data BEFORE creating webhook
    Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})

    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

    # Record a successful delivery and advance cursor
    Webhooks.record_delivery(webhook.id, %{store_seq: 1, status_code: 200, response_ms: 10})
    Webhooks.mark_delivered(webhook.id, 1)

    :ok = perform_job(Dust.Webhooks.CatchUpWorker, %{})

    assert all_enqueued(worker: Dust.Webhooks.DeliveryWorker) == []
  end
end
