defmodule Dust.Webhooks.PruneWorkerTest do
  use Dust.DataCase, async: false
  use Oban.Testing, repo: Dust.Repo

  alias Dust.{Accounts, Stores, Webhooks}

  test "prunes deliveries older than 7 days" do
    {:ok, user} = Accounts.create_user(%{email: "prune@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "prunetest"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://example.com"})

    # Insert an old delivery (8 days ago)
    old_time = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:microsecond)

    Dust.Repo.insert!(%Dust.Webhooks.DeliveryLog{
      webhook_id: webhook.id,
      store_seq: 1,
      status_code: 200,
      attempted_at: old_time
    })

    # Insert a recent delivery
    Webhooks.record_delivery(webhook.id, %{store_seq: 2, status_code: 200, response_ms: 10})

    # Run prune
    :ok = perform_job(Dust.Webhooks.PruneWorker, %{})

    # Only the recent one should remain
    deliveries = Webhooks.list_deliveries(webhook.id, limit: 100)
    assert length(deliveries) == 1
    assert hd(deliveries).store_seq == 2
  end
end
