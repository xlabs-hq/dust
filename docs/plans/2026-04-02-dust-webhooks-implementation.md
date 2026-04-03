# Webhook Notifications Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship webhook notifications — per-store HTTP push on every write, with HMAC signing, delivery logs, Oban-backed retry with catch-up, REST API, CLI commands, and Inertia/React management UI.

**Architecture:** Postgres tables for webhook config and delivery logs. Oban workers for delivery and catch-up. Req for HTTP calls. Channel calls `Webhooks.enqueue_deliveries/2` after each broadcast. Inertia page at `/:org/stores/:name/webhooks`.

**Tech Stack:** Elixir/Phoenix, Oban, Req, Ecto, React/Inertia, Tailwind

---

### Task 1: Migration — store_webhooks and webhook_deliveries tables

**Files:**
- Create: `server/priv/repo/migrations/<timestamp>_create_store_webhooks.exs`

**Step 1: Generate migration**

Run: `cd server && mix ecto.gen.migration create_store_webhooks`

**Step 2: Write migration**

```elixir
defmodule Dust.Repo.Migrations.CreateStoreWebhooks do
  use Ecto.Migration

  def change do
    create table(:store_webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :text, null: false
      add :secret, :text, null: false
      add :active, :boolean, null: false, default: true
      add :last_delivered_seq, :integer, null: false, default: 0
      add :failure_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:store_webhooks, [:store_id])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :webhook_id, references(:store_webhooks, type: :binary_id, on_delete: :delete_all), null: false
      add :store_seq, :integer, null: false
      add :status_code, :integer
      add :response_ms, :integer
      add :error, :text
      add :attempted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:webhook_deliveries, [:webhook_id])
    create index(:webhook_deliveries, [:attempted_at])

    execute(
      "ALTER TABLE store_webhooks ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE store_webhooks ALTER COLUMN id DROP DEFAULT"
    )

    execute(
      "ALTER TABLE webhook_deliveries ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE webhook_deliveries ALTER COLUMN id DROP DEFAULT"
    )
  end
end
```

**Step 3: Run migration**

Run: `cd server && mix ecto.migrate`

**Step 4: Commit**

```
git add server/priv/repo/migrations/
git commit -m "feat: add store_webhooks and webhook_deliveries tables"
```

---

### Task 2: Ecto Schemas — Webhook and DeliveryLog

**Files:**
- Create: `server/lib/dust/webhooks/webhook.ex`
- Create: `server/lib/dust/webhooks/delivery_log.ex`

**Step 1: Webhook schema**

```elixir
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
```

**Step 2: DeliveryLog schema**

```elixir
defmodule Dust.Webhooks.DeliveryLog do
  use Dust.Schema

  schema "webhook_deliveries" do
    field :store_seq, :integer
    field :status_code, :integer
    field :response_ms, :integer
    field :error, :string
    field :attempted_at, :utc_datetime_usec
  
    belongs_to :webhook, Dust.Webhooks.Webhook
  end
end
```

**Step 3: Commit**

```
git add server/lib/dust/webhooks/
git commit -m "feat: add Webhook and DeliveryLog Ecto schemas"
```

---

### Task 3: Webhooks Context Module

**Files:**
- Create: `server/lib/dust/webhooks.ex`
- Create: `server/test/dust/webhooks_test.exs`

**Step 1: Write failing tests**

```elixir
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
    assert String.length(webhook.secret) == 70  # "whsec_" + 64 hex chars
  end

  test "list_webhooks returns webhooks for a store", %{store: store} do
    {:ok, _} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    {:ok, _} = Webhooks.create_webhook(store, %{url: "https://b.com"})

    webhooks = Webhooks.list_webhooks(store)
    assert length(webhooks) == 2
  end

  test "delete_webhook removes a webhook", %{store: store} do
    {:ok, webhook} = Webhooks.create_webhook(store, %{url: "https://a.com"})
    assert :ok = Webhooks.delete_webhook(webhook.id, store.id)
    assert Webhooks.list_webhooks(store) == []
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
end
```

**Step 2: Implement context module**

```elixir
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

  def delete_webhook(webhook_id, store_id) do
    case Repo.get_by(Webhook, id: webhook_id, store_id: store_id) do
      nil -> {:error, :not_found}
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

    # Deactivate if failure_count >= 5
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
      preload: [:store]
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
```

**Step 3: Run tests, commit**

```
git add server/lib/dust/webhooks.ex server/test/dust/webhooks_test.exs
git commit -m "feat: add Webhooks context module with CRUD and delivery tracking"
```

---

### Task 4: DeliveryWorker — Oban Worker

**Files:**
- Create: `server/lib/dust/webhooks/delivery_worker.ex`
- Create: `server/test/dust/webhooks/delivery_worker_test.exs`

**Step 1: Write failing tests**

Test that:
- Worker signs the payload with HMAC-SHA256
- Worker POSTs to the webhook URL
- On success (2xx): updates last_delivered_seq, resets failure_count, logs delivery
- On failure: increments failure_count, logs delivery with error

Use `Req.Test` adapter or a simple mock approach — start a local Plug/Bandit server in the test, or use `Bypass` if available. Check deps. If neither is available, test the signing logic directly and mock the HTTP call.

Actually the simplest approach: extract the signing and payload building into pure functions, test those directly. For the HTTP integration, trust Req and test the worker's state management (mark_delivered, mark_failed) with a test adapter.

**Step 2: Implement worker**

```elixir
defmodule Dust.Webhooks.DeliveryWorker do
  use Oban.Worker, queue: :webhooks, max_attempts: 5

  alias Dust.Webhooks

  @timeout 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_id" => webhook_id, "event" => event}}) do
    webhook = Webhooks.get_webhook!(webhook_id)

    unless webhook.active do
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
          store_seq = event["store_seq"] || event[:store_seq]
          Webhooks.record_delivery(webhook_id, %{store_seq: store_seq, status_code: status, response_ms: elapsed})
          if store_seq, do: Webhooks.mark_delivered(webhook_id, store_seq)
          :ok

        {:ok, %{status: status}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          store_seq = event["store_seq"] || event[:store_seq]
          Webhooks.record_delivery(webhook_id, %{store_seq: store_seq || 0, status_code: status, response_ms: elapsed})
          Webhooks.mark_failed(webhook_id)
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          store_seq = event["store_seq"] || event[:store_seq]
          Webhooks.record_delivery(webhook_id, %{store_seq: store_seq || 0, error: inspect(reason)})
          Webhooks.mark_failed(webhook_id)
          {:error, inspect(reason)}
      end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # 1m, 5m, 30m, 2h, 12h
    [60, 300, 1800, 7200, 43200]
    |> Enum.at(attempt - 1, 43200)
  end

  def sign(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end
end
```

**Step 3: Add :webhooks queue to Oban config**

In `server/config/config.exs`, change:
```elixir
queues: [default: 10],
```
to:
```elixir
queues: [default: 10, webhooks: 10],
```

**Step 4: Run tests, commit**

```
git add server/lib/dust/webhooks/delivery_worker.ex server/test/dust/webhooks/delivery_worker_test.exs server/config/config.exs
git commit -m "feat: add webhook DeliveryWorker with HMAC signing and retry"
```

---

### Task 5: CatchUpWorker — Oban Cron

**Files:**
- Create: `server/lib/dust/webhooks/catch_up_worker.ex`
- Create: `server/test/dust/webhooks/catch_up_worker_test.exs`

**Step 1: Implement worker**

```elixir
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
      event: "entry.changed",
      store: "#{store.organization.slug}/#{store.name}",
      store_seq: op.store_seq,
      op: to_string(op.op),
      path: op.path,
      value: op.value,
      device_id: op.device_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
```

**Step 2: Add to Oban cron config**

In `server/config/config.exs`, add to the crontab:
```elixir
{"* * * * *", Dust.Webhooks.CatchUpWorker}
```

**Step 3: Write test, run, commit**

```
git add server/lib/dust/webhooks/catch_up_worker.ex server/test/dust/webhooks/catch_up_worker_test.exs server/config/config.exs
git commit -m "feat: add webhook CatchUpWorker for delivery gap recovery"
```

---

### Task 6: Wire Delivery into StoreChannel

**Files:**
- Modify: `server/lib/dust_web/channels/store_channel.ex`
- Modify: `server/test/dust_web/channels/store_channel_test.exs`

**Step 1: After each broadcast, enqueue webhook deliveries**

In the `handle_write_op` function (around line 81), after `broadcast!(socket, "event", format_event(db_op))`, add:

```elixir
enqueue_webhook_deliveries(socket, db_op)
```

Add a private function:

```elixir
defp enqueue_webhook_deliveries(socket, op) do
  store = socket.assigns.store_token.store
  org = store.organization

  event = %{
    event: "entry.changed",
    store: "#{org.slug}/#{store.name}",
    store_seq: op.store_seq,
    op: to_string(op.op),
    path: op.path,
    value: ValueCodec.unwrap(op.value),
    device_id: op.device_id,
    timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
  }

  Dust.Webhooks.enqueue_deliveries(store.id, event)
end
```

Also wire it into the `put_file` handler's success path.

**Step 2: Write test verifying write enqueues Oban jobs**

```elixir
test "write enqueues webhook delivery jobs", %{socket: socket, store: store} do
  {:ok, _webhook} = Dust.Webhooks.create_webhook(store, %{url: "https://example.com/hook"})

  {:ok, _, socket} =
    subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{"last_store_seq" => 0})

  push(socket, "write", %{
    "op" => "set", "path" => "a", "value" => "1", "client_op_id" => "o1"
  })

  assert_reply _, :ok, _

  # Verify an Oban job was enqueued
  assert [%Oban.Job{worker: "Dust.Webhooks.DeliveryWorker"}] =
    all_enqueued(worker: Dust.Webhooks.DeliveryWorker)
end
```

Note: Use `use Oban.Testing, repo: Dust.Repo` in the test module for `all_enqueued/1`.

**Step 3: Run tests, commit**

```
git add server/lib/dust_web/channels/store_channel.ex server/test/dust_web/channels/store_channel_test.exs
git commit -m "feat: wire webhook delivery into store channel write path"
```

---

### Task 7: WebhookController — REST API

**Files:**
- Create: `server/lib/dust_web/controllers/api/webhook_controller.ex`
- Modify: `server/lib/dust_web/router.ex`
- Create: `server/test/dust_web/controllers/api/webhook_controller_test.exs`

**Step 1: Implement controller**

Actions: `index`, `create`, `delete`, `ping`, `deliveries`

- `create` generates the webhook, returns the secret (once)
- `index` lists webhooks without secrets
- `delete` removes a webhook
- `ping` sends a test payload synchronously, reactivates on success
- `deliveries` returns delivery log for a webhook

All actions verify token scoping (store_token.store_id == store.id) and appropriate permissions (write for create/delete, read for index/deliveries/ping).

For `ping`: build a ping payload, call `DeliveryWorker.sign/2` for the signature, use `Req.post` inline (not via Oban), return the status code and response time. On 2xx, call `Webhooks.reactivate/1`.

**Step 2: Add routes**

In `server/lib/dust_web/router.ex`, inside the `api_auth` scope:

```elixir
get "/stores/:org/:store/webhooks", WebhookController, :index
post "/stores/:org/:store/webhooks", WebhookController, :create
delete "/stores/:org/:store/webhooks/:id", WebhookController, :delete
post "/stores/:org/:store/webhooks/:id/ping", WebhookController, :ping
get "/stores/:org/:store/webhooks/:id/deliveries", WebhookController, :deliveries
```

**Step 3: Write controller tests**

Cover: create returns secret, list omits secret, delete works, ping sends HTTP, 404/403 cases.

**Step 4: Run tests, commit**

```
git add server/lib/dust_web/controllers/api/webhook_controller.ex server/lib/dust_web/router.ex server/test/dust_web/controllers/api/webhook_controller_test.exs
git commit -m "feat: add webhook REST API endpoints"
```

---

### Task 8: Delivery Log Pruning

**Files:**
- Create: `server/lib/dust/webhooks/prune_worker.ex`
- Modify: `server/config/config.exs` (add to crontab)

**Step 1: Implement worker**

Simple Oban cron worker that deletes deliveries older than 7 days:

```elixir
defmodule Dust.Webhooks.PruneWorker do
  use Oban.Worker, queue: :default

  import Ecto.Query

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.utc_now() |> DateTime.add(-7, :day)

    Dust.Repo.delete_all(
      from(d in Dust.Webhooks.DeliveryLog, where: d.attempted_at < ^cutoff)
    )

    :ok
  end
end
```

**Step 2: Add daily cron**

```elixir
{"0 3 * * *", Dust.Webhooks.PruneWorker}
```

**Step 3: Commit**

```
git add server/lib/dust/webhooks/prune_worker.ex server/config/config.exs
git commit -m "feat: add daily delivery log pruning (7-day retention)"
```

---

### Task 9: CLI — Webhook Commands

**Files:**
- Create: `cli/src/dust/commands/webhook.cr`
- Modify: `cli/src/dust/cli.cr`
- Modify: `cli/src/dust.cr`

**Step 1: Implement webhook commands**

Subcommands: `create`, `list`, `delete`, `ping`, `deliveries`

Follow the same HTTP pattern as export/import/clone commands — derive HTTP URL from config, Bearer token auth, parse JSON responses.

`dust webhook create org/store https://example.com/hook` — POST, display the secret prominently with a warning that it's shown only once.

`dust webhook list org/store` — GET, table format with id, url, active, last_delivered_seq, failure_count.

`dust webhook delete org/store <id>` — DELETE.

`dust webhook ping org/store <id>` — POST, display status code and response time.

`dust webhook deliveries org/store <id>` — GET, table format with seq, status, ms, error, time.

**Step 2: Add CLI routing**

In `cli/src/dust/cli.cr`, add `"webhook"` command with subcommand dispatch.

**Step 3: Build CLI, commit**

```
git add cli/src/dust/commands/webhook.cr cli/src/dust/cli.cr cli/src/dust.cr
git commit -m "feat: add CLI webhook commands"
```

---

### Task 10: Inertia Page — Webhook Management UI

**Files:**
- Create: `server/lib/dust_web/controllers/webhook_page_controller.ex`
- Create: `server/assets/js/pages/Stores/Webhooks.tsx`
- Modify: `server/lib/dust_web/router.ex` (add browser route)
- Modify: `server/assets/js/pages/Stores/Show.tsx` (add link)

**Step 1: Create controller**

```elixir
defmodule DustWeb.WebhookPageController do
  use DustWeb, :controller
  import Inertia.Controller

  alias Dust.{Stores, Webhooks}

  def index(conn, %{"name" => store_name}) do
    scope = conn.assigns.current_scope
    store = Stores.get_store_by_org_and_name!(scope.organization, store_name)
    webhooks = Webhooks.list_webhooks(store)

    conn
    |> assign(:page_title, "Webhooks — #{store.name}")
    |> render_inertia("Stores/Webhooks", %{
      store: serialize_store(store, scope.organization),
      webhooks: Enum.map(webhooks, &serialize_webhook/1)
    })
  end

  def create(conn, %{"name" => store_name, "url" => url}) do
    scope = conn.assigns.current_scope
    store = Stores.get_store_by_org_and_name!(scope.organization, store_name)

    case Webhooks.create_webhook(store, %{url: url}) do
      {:ok, webhook} ->
        conn
        |> put_flash(:info, "Webhook created. Secret: #{webhook.secret}")
        |> redirect(to: ~p"/#{scope.organization.slug}/stores/#{store.name}/webhooks")

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Invalid URL")
        |> redirect(to: ~p"/#{scope.organization.slug}/stores/#{store.name}/webhooks")
    end
  end

  def delete(conn, %{"name" => store_name, "id" => webhook_id}) do
    scope = conn.assigns.current_scope
    store = Stores.get_store_by_org_and_name!(scope.organization, store_name)
    Webhooks.delete_webhook(webhook_id, store.id)

    conn
    |> put_flash(:info, "Webhook deleted")
    |> redirect(to: ~p"/#{scope.organization.slug}/stores/#{store.name}/webhooks")
  end

  defp serialize_store(store, org) do
    %{id: store.id, name: store.name, full_name: "#{org.slug}/#{store.name}"}
  end

  defp serialize_webhook(webhook) do
    %{
      id: webhook.id,
      url: webhook.url,
      active: webhook.active,
      last_delivered_seq: webhook.last_delivered_seq,
      failure_count: webhook.failure_count,
      created_at: webhook.inserted_at
    }
  end
end
```

**Step 2: Add routes**

In the org-scoped browser routes:
```elixir
get "/stores/:name/webhooks", WebhookPageController, :index
post "/stores/:name/webhooks", WebhookPageController, :create
delete "/stores/:name/webhooks/:id", WebhookPageController, :delete
```

**Step 3: Create React component**

Create `server/assets/js/pages/Stores/Webhooks.tsx`:

- Header with store name and back link to store show page
- Create form: URL input + submit button
- Webhook list as cards/rows: URL, status badge (active/inactive), last_delivered_seq, failure_count, created_at
- Delete button per webhook with confirmation
- The secret is shown via flash message after creation (shown once, from the redirect)
- Link to delivery log (could be inline expandable or a separate fetch)

Use existing UI components: Table, Badge, Button, Input, Card.

For delete, use an Inertia `router.delete()` call.

For the delivery log per webhook, fetch via `usePage` props or a client-side fetch. Simplest: include deliveries in the page props (last 10 per webhook). For the full list, add an API call.

**Step 4: Add link from Store Show page**

In `server/assets/js/pages/Stores/Show.tsx`, add a "Webhooks" button/link near the "View full audit log" button:

```tsx
<Button variant="outline" size="sm" asChild>
  <Link href={`/${orgSlug}/stores/${store.name}/webhooks`}>
    Manage webhooks
  </Link>
</Button>
```

**Step 5: Commit**

```
git add server/lib/dust_web/controllers/webhook_page_controller.ex server/assets/js/pages/Stores/Webhooks.tsx server/lib/dust_web/router.ex server/assets/js/pages/Stores/Show.tsx
git commit -m "feat: add Inertia webhook management page"
```

---

### Task 11: Full Test Suite + Final Verification

**Step 1: Run full server test suite**

Run: `cd server && mix test`

**Step 2: Run mix format**

Run: `cd server && mix format`

**Step 3: Build CLI**

Run: `cd cli && shards build`

**Step 4: Commit formatting, verify**

```
git add -A
git commit -m "style: apply mix format"
```

Run: `cd server && mix test`
Expected: All pass.
