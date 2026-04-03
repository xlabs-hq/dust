defmodule Dust.WebhooksTest do
  use Dust.DataCase, async: false
  use Oban.Testing, repo: Dust.Repo

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

  test "mark_delivered updates last_delivered_seq based on contiguous delivery log", %{
    store: store
  } do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})

    # Record contiguous successful deliveries for seqs 1, 2, 3
    for seq <- 1..3 do
      Webhooks.record_delivery(webhook.id, %{store_seq: seq, status_code: 200, response_ms: 10})
    end

    Webhooks.mark_delivered(webhook.id, 3)
    updated = Webhooks.get_webhook!(webhook.id)
    assert updated.last_delivered_seq == 3
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

  describe "contiguous cursor advancement (Bug 1)" do
    test "out-of-order delivery does not skip events", %{store: store} do
      {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})

      # Record successful delivery for seq 2 before seq 1
      Webhooks.record_delivery(webhook.id, %{store_seq: 2, status_code: 200, response_ms: 10})
      Webhooks.mark_delivered(webhook.id, 2)

      updated = Webhooks.get_webhook!(webhook.id)
      # Should NOT advance to 2 because seq 1 is missing
      assert updated.last_delivered_seq == 0
    end

    test "contiguous deliveries advance cursor correctly", %{store: store} do
      {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})

      # Deliver seq 2 first, then seq 1
      Webhooks.record_delivery(webhook.id, %{store_seq: 2, status_code: 200, response_ms: 10})
      Webhooks.mark_delivered(webhook.id, 2)

      updated = Webhooks.get_webhook!(webhook.id)
      assert updated.last_delivered_seq == 0

      # Now deliver seq 1 — cursor should advance to 2
      Webhooks.record_delivery(webhook.id, %{store_seq: 1, status_code: 200, response_ms: 10})
      Webhooks.mark_delivered(webhook.id, 1)

      updated = Webhooks.get_webhook!(webhook.id)
      assert updated.last_delivered_seq == 2
    end

    test "gap in deliveries stops cursor at the gap", %{store: store} do
      {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})

      # Deliver seq 1, 2, and 4 (skip 3)
      for seq <- [1, 2, 4] do
        Webhooks.record_delivery(webhook.id, %{store_seq: seq, status_code: 200, response_ms: 10})
        Webhooks.mark_delivered(webhook.id, seq)
      end

      updated = Webhooks.get_webhook!(webhook.id)
      # Should stop at 2 because 3 is missing
      assert updated.last_delivered_seq == 2
    end

    test "failed deliveries do not count for contiguous advancement", %{store: store} do
      {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})

      # Seq 1 succeeds, seq 2 fails, seq 3 succeeds
      Webhooks.record_delivery(webhook.id, %{store_seq: 1, status_code: 200, response_ms: 10})
      Webhooks.mark_delivered(webhook.id, 1)

      Webhooks.record_delivery(webhook.id, %{store_seq: 2, status_code: 500, response_ms: 10})
      # Seq 2 failed — don't call mark_delivered

      Webhooks.record_delivery(webhook.id, %{store_seq: 3, status_code: 200, response_ms: 10})
      Webhooks.mark_delivered(webhook.id, 3)

      updated = Webhooks.get_webhook!(webhook.id)
      # Should stop at 1 because seq 2 was not successfully delivered
      assert updated.last_delivered_seq == 1
    end
  end

  describe "Sync.write triggers webhook fanout (Bug 2)" do
    setup %{store: store} do
      store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
      File.rm_rf!(store_dir)
      on_exit(fn -> File.rm_rf!(store_dir) end)
      %{store: store}
    end

    test "Sync.write enqueues delivery jobs for active webhooks", %{store: store} do
      {:ok, _webhook} = Webhooks.create_webhook(store, %{url: "https://a.com/hook"})
      {:ok, _webhook2} = Webhooks.create_webhook(store, %{url: "https://b.com/hook"})

      {:ok, _op} =
        Dust.Sync.write(store.id, %{
          op: :set,
          path: "x",
          value: "hello",
          device_id: "test",
          client_op_id: "bug2-test"
        })

      jobs = all_enqueued(worker: Dust.Webhooks.DeliveryWorker)
      assert length(jobs) == 2
    end

    test "Sync.write sends materialized values in webhook events (Bug 3)", %{store: store} do
      {:ok, _webhook} = Webhooks.create_webhook(store, %{url: "https://a.com/hook"})

      # Write a set op — value should be the plain value, not wrapped
      {:ok, _op} =
        Dust.Sync.write(store.id, %{
          op: :set,
          path: "greeting",
          value: "hello",
          device_id: "test",
          client_op_id: "bug3-test"
        })

      [job] = all_enqueued(worker: Dust.Webhooks.DeliveryWorker)
      event = job.args["event"]
      assert event["value"] == "hello"
      assert event["op"] == "set"
      assert event["path"] == "greeting"
      assert event["store_seq"] == 1
      assert is_binary(event["store"])
      assert String.contains?(event["store"], "/")
    end
  end
end
