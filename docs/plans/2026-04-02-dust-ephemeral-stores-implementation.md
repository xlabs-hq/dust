# Ephemeral Stores Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add TTL-based ephemeral stores that auto-archive after expiry.

**Architecture:** `expires_at` column on stores. Oban cron archives expired stores every minute. Soft-delete only — no file/data destruction.

**Tech Stack:** Elixir/Phoenix, Oban, Ecto

---

### Task 1: Migration — add expires_at to stores

Generate and write migration adding `expires_at` (nullable `utc_datetime_usec`) to stores table.

Run migration. Verify existing tests still pass.

Commit: `feat: add expires_at column to stores table`

---

### Task 2: Schema + create_store changes

Modify `Dust.Stores.Store` schema to include `expires_at` field. Update changeset to cast it.

Modify `Dust.Stores.create_store/2` to accept `ttl` in attrs. If `ttl` is present (integer seconds), compute `expires_at = DateTime.utc_now() + ttl`. Pass `expires_at` into the changeset.

Write tests: create store with TTL, verify `expires_at` is set correctly. Create store without TTL, verify `expires_at` is nil.

Commit: `feat: support TTL on store creation`

---

### Task 3: Expiry Worker

Create `Dust.Workers.StoreExpiry` — Oban cron worker running every minute.

Finds stores where `status: :active` and `expires_at IS NOT NULL` and `expires_at < now()`. For each:
1. Set `status: :archived`
2. Stop Writer GenServer via `Dust.Sync.Writer.stop(store_id)` — need to add this function. It looks up the Writer in the Registry and sends a stop. If not running, no-op.
3. Broadcast `"phx_close"` on the store's channel topic to disconnect clients.

Add to Oban crontab: `{"* * * * *", Dust.Workers.StoreExpiry}`

Writer.stop/1: look up pid in Registry, call `GenServer.stop(pid, :normal)`. Return `:ok` regardless.

Write tests: create ephemeral store, set expires_at to the past, run worker, verify status is archived.

Commit: `feat: add store expiry worker`

---

### Task 4: API + CLI changes

Modify `StoreApiController.create` to pass `ttl` from params into `create_store`.

Modify `StoreApiController.index` to include `expires_at` in the store serialization.

Modify CLI `dust create` to accept `--ttl N` flag and pass it in the POST body.

Modify CLI `dust status` to display time remaining for ephemeral stores (from the status channel event — add `expires_at` to the `build_status` response in StoreChannel).

Write controller test: create store with TTL via API, verify `expires_at` in response.

Commit: `feat: expose TTL in API, CLI, and status`

---

### Task 5: Web UI + final verification

Update the store show page and Inertia controller to display `expires_at` for ephemeral stores (show a badge or countdown).

Update the store create form/controller if there's one to support TTL.

Run full test suite. Format. Build CLI.

Commit: `feat: display ephemeral store TTL in web UI`
