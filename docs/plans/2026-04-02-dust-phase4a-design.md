# Phase 4A Design: Production Essentials

Four features that make the server deployable: telemetry, rate limiting, billing limits, log compaction.

## 1. Telemetry + Health Endpoints

**Health routes** (no auth, added above `/:org` scope):
- `GET /healthz` — 200 if Endpoint is up. No DB check.
- `GET /readyz` — 200 if DB pool responds (`SELECT 1`) and PubSub is alive. 503 otherwise.

**:telemetry events:**
- `[:dust, :write, :start|:stop|:exception]` — wraps `Writer.do_write/2` with `:telemetry.span`. Measurements: duration. Metadata: store_id, op, path.
- `[:dust, :connection, :join|:leave]` — emitted in StoreChannel join and terminate. Metadata: store_id, device_id.

**Structured logging:**
- On channel join: `Logger.metadata(store_id: store.id, device_id: socket.assigns.device_id)`.
- Propagates to all log lines within the channel process.

No dependencies. No migrations. ~4 files.

## 2. Rate Limiting

**Dependency:** `{:hammer, "~> 6.0"}` — ETS-backed token bucket.

**Module:** `Dust.RateLimiter` — `check(token_id, :write | :read)` => `:ok | {:error, :rate_limited, retry_after_ms}`.

**Scope:** Per-token (keyed by `store_token.id`). All connections sharing a token share the limit. Protects the Writer from multi-connection abuse.

**Default limits:** 100 writes/min, 1000 reads/min. Application config, tunable.

**Call sites:**
- `StoreChannel.handle_in("write")` — before `Sync.write`
- `StoreChannel.handle_in("put_file")` — before `Sync.write`
- MCP write tools — before `Dust.Sync.write`

**Response:** WebSocket: `{:error, %{reason: "rate_limited", retry_after_ms: N}}`. MCP: error text. REST: 429.

**Supervision:** `{Hammer.Backend.ETS, []}` in application.ex.

No migration. ~50 LOC.

## 3. Billing / Limit Enforcement

No Stripe. Just the enforcement engine.

**Schema:** Add `plan` string column to `organizations` (default: `"free"`). One migration.

**Plan limits:** `Dust.Billing.Limits` — pure functions:

```
free:  1 store, 1K keys/store, 100MB files, 7-day retention
pro:   unlimited stores, 100K keys/store, 10GB files, 30-day retention
team:  unlimited stores, 1M keys/store, 100GB files, 1-year retention
```

**Enforcement points:**
- **Store count:** Checked in `Stores.create_store/2`. `count(stores WHERE org_id AND active)` vs plan limit.
- **Key count:** Checked in StoreChannel before `Sync.write` for ops that create new keys (set with new paths, merge with net-new paths). `count(store_entries WHERE store_id)` vs plan limit.
- **File storage:** Checked in StoreChannel before `put_file` upload. `sum(blobs.size)` for store vs plan limit.

**How the org reaches the channel:** `store_token` already preloads `store.organization`. Channel reads `organization.plan` from socket assigns.

**Rejection shape:** `{:error, :limit_exceeded, %{dimension: :keys, current: N, limit: M}}`. SDK already handles write rejections.

~3 new files, 1 migration.

## 4. Log Compaction

**Trigger:** Oban cron job (`Dust.Workers.Compaction`) every hour. Per store:
1. Op count > 10,000 threshold
2. Either all connected clients acked past compaction point, OR oldest op is older than plan's `retention_days`

**Compaction operation** (transaction):
1. Read current `store_entries` — this is the snapshot
2. Get `max(store_seq)` — becomes `snapshot_seq`
3. Insert `store_snapshots` row with `{store_id, snapshot_seq, snapshot_data}`
4. Delete `store_ops` where `store_seq <= snapshot_seq`
5. Delete older snapshots (keep only latest)

**Writer seq fix:** `do_write` reads `max(store_seq)` from ops AND `max(snapshot_seq)` from snapshots. Takes the higher as the floor. Prevents seq regression after compaction.

**Catch-up sync change:** In `StoreChannel.handle_info({:catch_up, last_seq})`:
- If `last_seq` < latest `snapshot_seq`: push `"snapshot"` message with full snapshot data, then ops after `snapshot_seq`
- Otherwise: send ops as before (batched path)

**SDK snapshot handler:** New `handle_message("snapshot")` in Connection. Writes all entries to cache as bulk replace, sets `last_store_seq` to `snapshot_seq`.

**Retention:** Plan's `retention_days` controls the time-based compaction fallback. Free (7d) compacts aggressively. Pro (30d) keeps more history.

1 new Oban worker, changes to Writer, StoreChannel, SDK Connection + SyncEngine.

## Implementation Order

1. **Telemetry** — no dependencies, pure additive
2. **Rate limiting** — needs Hammer dep, otherwise independent
3. **Billing limits** — needs migration, enforcement in channel
4. **Log compaction** — depends on billing (retention_days), most complex
