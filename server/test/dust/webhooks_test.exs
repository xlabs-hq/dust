defmodule Dust.WebhooksTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Webhooks}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "webhook@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "whtest"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store, org: org}
  end

  test "create_webhook generates secret and returns it", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://example.com/hook"})
    assert webhook.url == "https://example.com/hook"
    assert webhook.active == true
    assert String.starts_with?(webhook.secret, "whsec_")
    assert String.length(webhook.secret) == 70
  end

  test "create_webhook rejects invalid URL", %{store: store} do
    {:error, changeset} = Webhooks.create_webhook(store, %{url: "not-a-url"})
    assert changeset.errors[:url]
  end

  test "list_webhooks returns webhooks for a store", %{store: store} do
    {:ok, _} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    {:ok, _} = Webhooks.create_webhook(store, %{url: "https://b.com"})
    assert length(Webhooks.list_webhooks(store)) == 2
  end

  test "delete_webhook removes a webhook", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    assert :ok = Webhooks.delete_webhook(webhook.id, store.id)
    assert Webhooks.list_webhooks(store) == []
  end

  test "delete_webhook returns error for wrong store_id", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    assert {:error, :not_found} = Webhooks.delete_webhook(webhook.id, Ecto.UUID.generate())
  end

  test "record_delivery logs a delivery attempt", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    Webhooks.record_delivery(webhook.id, %{store_seq: 1, status_code: 200, response_ms: 42})
    deliveries = Webhooks.list_deliveries(webhook.id, limit: 10)
    assert length(deliveries) == 1
    assert hd(deliveries).status_code == 200
  end

  test "mark_delivered updates last_delivered_seq and resets failure_count", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    Webhooks.mark_delivered(webhook.id, 42)
    updated = Webhooks.get_webhook!(webhook.id)
    assert updated.last_delivered_seq == 42
    assert updated.failure_count == 0
  end

  test "mark_failed increments failure_count and deactivates at 5", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    Enum.each(1..5, fn _ -> Webhooks.mark_failed(webhook.id) end)
    updated = Webhooks.get_webhook!(webhook.id)
    assert updated.failure_count == 5
    assert updated.active == false
  end

  test "reactivate sets active true and resets failure_count", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    Enum.each(1..5, fn _ -> Webhooks.mark_failed(webhook.id) end)
    Webhooks.reactivate(webhook.id)
    updated = Webhooks.get_webhook!(webhook.id)
    assert updated.active == true
    assert updated.failure_count == 0
  end

  test "active_webhooks_for_store excludes inactive", %{store: store} do
    {:ok, _} = Webhooks.create_webhook(store, %{url: "https://active.com"})
    {:ok, wh2} = Webhooks.create_webhook(store, %{url: "https://inactive.com"})
    Enum.each(1..5, fn _ -> Webhooks.mark_failed(wh2.id) end)

    active = Webhooks.active_webhooks_for_store(store.id)
    assert length(active) == 1
    assert hd(active).url == "https://active.com"
  end

  test "webhooks_needing_catchup finds behind webhooks", %{store: store} do
    {:ok, _wh} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    # Write data to advance the store seq
    Dust.Sync.write(store.id, %{
      op: :set,
      path: "a",
      value: "1",
      device_id: "d",
      client_op_id: "o1"
    })

    behind = Webhooks.webhooks_needing_catchup()
    assert length(behind) >= 1
  end
end
