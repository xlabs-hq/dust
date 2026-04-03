# Webhook Notifications Design

Push HTTP notifications to external endpoints when a store changes. One store has many webhooks. Every write fires every active webhook. No filtering — the receiver decides what to act on.

## Core Contract

Writes are fire-and-forget. The local state never changes from a write response. All confirmed state changes flow through one pathway — WebSocket events for persistent connections, webhooks for environments that can't hold them (Rails/Puma, Python/Gunicorn). The receiver maintains a `last_processed_seq` and skips events at or below it.

## API

### Create

```
POST /api/stores/:org/:store/webhooks
Body: {"url": "https://example.com/hook"}

201 Created
{
  "id": "...",
  "url": "https://example.com/hook",
  "secret": "whsec_7f3a...d41b",
  "active": true,
  "created_at": "2026-04-02T14:00:00Z"
}
```

The secret is returned once, at creation. Never again.

### List

```
GET /api/stores/:org/:store/webhooks

200 OK
{"webhooks": [
  {"id": "...", "url": "https://example.com/hook", "active": true,
   "last_delivered_seq": 42, "failure_count": 0, "created_at": "..."}
]}
```

No secret in the list response.

### Delete

```
DELETE /api/stores/:org/:store/webhooks/:id

200 OK
{"ok": true}
```

### Ping

```
POST /api/stores/:org/:store/webhooks/:id/ping

200 OK
{"ok": true, "status_code": 200, "response_ms": 42}
```

Synchronous. Sends a test payload and returns the target's response. On success, reactivates an inactive webhook.

### Delivery Log

```
GET /api/stores/:org/:store/webhooks/:id/deliveries?limit=20

200 OK
{"deliveries": [
  {"store_seq": 42, "status_code": 200, "response_ms": 38, "error": null, "attempted_at": "..."},
  {"store_seq": 41, "status_code": 500, "response_ms": 2100, "error": null, "attempted_at": "..."}
]}
```

### CLI

```
dust webhook create org/store https://example.com/hook
dust webhook list org/store
dust webhook delete org/store <id>
dust webhook ping org/store <id>
dust webhook deliveries org/store <id> [--limit 50]
```

## Event Payload

```json
{
  "event": "entry.changed",
  "store": "org/store",
  "store_seq": 42,
  "op": "set",
  "path": "users.alice.name",
  "value": "Alice",
  "device_id": "dev_abc",
  "timestamp": "2026-04-02T14:00:00Z"
}
```

Ping payload:

```json
{
  "event": "ping",
  "store": "org/store",
  "timestamp": "2026-04-02T14:00:00Z"
}
```

## Signing

HMAC-SHA256 of the raw JSON body using the webhook secret. Delivered as:

```
X-Dust-Signature: sha256=<hex digest>
```

Secret format: `whsec_` prefix + 32 bytes of `crypto.strong_rand_bytes` hex-encoded.

## Schema

### store_webhooks

```sql
CREATE TABLE store_webhooks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  url TEXT NOT NULL,
  secret TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  last_delivered_seq INTEGER NOT NULL DEFAULT 0,
  failure_count INTEGER NOT NULL DEFAULT 0,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX store_webhooks_store_id_idx ON store_webhooks(store_id);
```

### webhook_deliveries

```sql
CREATE TABLE webhook_deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  webhook_id UUID NOT NULL REFERENCES store_webhooks(id) ON DELETE CASCADE,
  store_seq INTEGER NOT NULL,
  status_code INTEGER,
  response_ms INTEGER,
  error TEXT,
  attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX webhook_deliveries_webhook_id_idx ON webhook_deliveries(webhook_id);
```

Delivery log retention: 7 days. Oban cron prunes older rows.

## Delivery Flow

1. Writer commits op, channel broadcasts event via PubSub (already happening).
2. After broadcast, `Dust.Webhooks.enqueue_deliveries(store_id, event)` loads active webhooks for the store and inserts one Oban job per webhook.
3. Oban worker signs the payload, POSTs with 5-second timeout.
4. On 2xx: update `last_delivered_seq`, reset `failure_count` to 0, log delivery.
5. On failure: increment `failure_count`, log delivery with error. At 5 consecutive failures, set `active: false`. Oban retries with exponential backoff (1m, 5m, 30m, 2h, 12h).

## Catch-Up on Recovery

Oban cron job runs every minute. Finds webhooks where `last_delivered_seq < store.current_seq` and `active = true`. Enqueues deliveries for the missed ops (reads from SQLite via `Sync.get_ops_since`).

Covers server restarts, missed PubSub events, and delivery gaps.

## Oban Configuration

Dedicated `:webhooks` queue, concurrency 10. Keeps webhook delivery separate from compaction and other jobs.

## Server Modules

- `Dust.Webhooks` — context module. CRUD, `enqueue_deliveries/2`, secret generation.
- `Dust.Webhooks.Webhook` — Ecto schema.
- `Dust.Webhooks.DeliveryWorker` — Oban worker. Sign, POST, update state, log delivery.
- `Dust.Webhooks.CatchUpWorker` — Oban cron. Scan for gaps, enqueue backfill.
- `Dust.Webhooks.DeliveryLog` — Ecto schema for `webhook_deliveries`.
- `DustWeb.Api.WebhookController` — REST endpoints.

## Web UI

Inertia/React page at `/:org/stores/:name/webhooks`.

- List webhooks with status (active/inactive), URL, last delivered seq, failure count
- Create form (URL input, shows secret once on success)
- Delete button with confirmation
- Ping button with inline result
- Expandable delivery log per webhook (last 20 deliveries)

Linked from the store show page.

## Deferred

- Webhook editing (delete and recreate)
- Rate limiting on delivery
- Batching multiple ops into one delivery
- Server-side filtering or pattern matching
