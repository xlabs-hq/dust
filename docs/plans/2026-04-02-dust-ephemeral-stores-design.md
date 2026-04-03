# Ephemeral Stores Design

Stores with a TTL that auto-archive after expiry. The core primitive for AI agent sessions — scratch space that cleans itself up.

## Schema

Add `expires_at` column to `stores` table. Nullable. Existing stores have `expires_at: nil` (permanent). Ephemeral stores compute `expires_at = now() + ttl` at creation.

## Create

`POST /api/stores` accepts optional `ttl` param (integer, seconds):

```json
{"name": "session-123", "ttl": 3600}
```

Server computes `expires_at` and stores it. Response includes `expires_at`.

CLI: `dust create org/store --ttl 3600`

No TTL means permanent (existing behavior).

## Behavior While Alive

Identical to regular stores. Same ops, same sync, same webhooks, same billing.

## Expiry

Oban cron job runs every minute. Finds active stores where `expires_at IS NOT NULL AND expires_at < now()`. For each:

1. Set `status: archived`
2. Stop the Writer GenServer if running
3. Broadcast channel close to connected clients

Soft-delete only. SQLite files stay on disk. Postgres rows stay. Blob refcounts stay. An operator can restore by setting `status: active` and optionally a new `expires_at`.

## API Surface

`GET /api/stores` and store show page include `expires_at` in the response. CLI `dust status` displays time remaining for ephemeral stores.

## No Capver Bump

Ephemeral stores are identical on the wire. The TTL is a server-side lifecycle concern. Existing clients work without changes.

## Deferred

- Agent presence (dropped — not clearly useful for AI agents)
- Context store type (let naming conventions emerge from usage)
- Hard purge of expired stores (manual operator action for now)
