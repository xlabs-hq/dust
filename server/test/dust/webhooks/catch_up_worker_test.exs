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
    {:ok, _webhook} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

    # Write data to advance the store seq
    Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
    Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})

    # Run catch-up worker
    :ok = perform_job(Dust.Webhooks.CatchUpWorker, %{})

    # Should have enqueued 2 delivery jobs
    assert length(all_enqueued(worker: Dust.Webhooks.DeliveryWorker)) == 2
  end

  test "skips webhooks that are caught up", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})
    Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})

    # Mark as caught up
    Webhooks.mark_delivered(webhook.id, 1)

    :ok = perform_job(Dust.Webhooks.CatchUpWorker, %{})

    assert all_enqueued(worker: Dust.Webhooks.DeliveryWorker) == []
  end
end
