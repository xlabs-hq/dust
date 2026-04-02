# Phase 4B Design: SQLite-per-Store

Replace the multi-tenant Postgres store data layer with per-store SQLite files. Postgres stays for identity/auth/billing. Store data (ops, entries, snapshots) moves to individual SQLite files managed by the Writer GenServer.

## Why

A single Postgres handling both user ops and all store data won't scale. The Writer GenServer already serializes writes per store — SQLite's single-writer model is a perfect match. Per-store files give free isolation, trivial backup (copy the file), and horizontal scaling by distributing files.

## Architecture

```
Postgres (Ecto)                    SQLite (Exqlite, per store)
─────────────────                  ─────────────────────────────
accounts                           {store_data_dir}/{org}/{store}.db
organizations                        ├── store_ops
organization_memberships              ├── store_entries
users                                 └── store_snapshots
devices
stores (metadata only)
store_tokens
blobs
```

## File Layout

Configurable via `config :dust, :store_data_dir`. Default: `priv/stores` (dev), `/var/lib/dust/stores` (prod). Path: `{store_data_dir}/{org_slug}/{store_name}.db`.

## SQLite Schema (per file)

```sql
PRAGMA journal_mode=WAL;

CREATE TABLE store_ops (
  store_seq INTEGER PRIMARY KEY,
  op TEXT NOT NULL,
  path TEXT NOT NULL,
  value TEXT,
  type TEXT NOT NULL,
  device_id TEXT NOT NULL,
  client_op_id TEXT NOT NULL,
  inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE store_entries (
  path TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  type TEXT NOT NULL,
  seq INTEGER NOT NULL
);

CREATE TABLE store_snapshots (
  snapshot_seq INTEGER PRIMARY KEY,
  snapshot_data TEXT NOT NULL,
  inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
```

No store_id columns needed. No UUIDs. `store_seq` is the natural PK for ops.

## Writer GenServer Changes

Grows from "write serializer calling Ecto" to "write serializer owning a SQLite connection."

**Lifecycle:**
1. `ensure_started` — same (DynamicSupervisor + Registry)
2. `init` — look up store metadata from Postgres, compute file path, open Exqlite connection, `CREATE TABLE IF NOT EXISTS`, store conn in state
3. `handle_call({:write, ...})` — raw SQL via Exqlite
4. `handle_info(:timeout)` — close Exqlite connection, stop (15-min idle)

**State:** `%{store_id, db, store_path, org_slug, store_name}`

## StoreDB Module

`Dust.Sync.StoreDB` — manages file paths and read connections:

- `path(store_id)` — returns file path (looks up org/store from Postgres, caches)
- `read_conn(store_id)` — opens read-only Exqlite connection
- `ensure_created(store_id)` — creates file + tables if not exists

## Read Path

SQLite supports unlimited concurrent readers with WAL mode. Read-heavy operations (catch-up sync, get_entry, billing checks) open read-only connections on demand. Hot paths (catch-up batch) reuse one connection across the batch.

## Cross-Store Queries

Admin dashboard needs aggregate stats. Solution: cached `entry_count` and `current_seq` columns on the Postgres `stores` table, updated by the Writer after writes.

## Compaction

Moves inside the Writer GenServer. Oban job sends `{:compact, retention_days}` cast to the Writer. The Writer does snapshot + delete + VACUUM in one place. No cross-process race condition.

## Store Lifecycle

- **Create:** Postgres metadata row. SQLite file created lazily on first write.
- **Delete:** Soft-delete in Postgres. Oban job stops Writer, deletes SQLite file.
- **Backup:** Copy the SQLite file.
- **Export:** Stream the SQLite file over HTTP. Or JSONL for compatibility.
- **Clone:** Copy the file + new Postgres metadata. Instant.

## Test Strategy

- Temp store data dir per test run (`System.tmp_dir!/dust_test_{random}`)
- Each test's store gets its own SQLite file naturally
- File deletion = cleanup (no sandbox needed for store data)
- Postgres sandbox stays for accounts/tokens metadata

## Implementation Order

1. Add Exqlite dep, create StoreDB module
2. Rewrite Writer to use SQLite
3. Rewrite Sync read functions
4. Rewrite Rollback
5. Update Compaction to message Writer
6. Update channel catch-up
7. Update tests
8. Migration Mix task (Postgres → SQLite)
9. Drop old Postgres store tables

## Deferred

- MessagePack wire format (Phase 4C+)
- Capability versioning negotiation (Phase 4C+)
- Ed25519 store signing (Phase 5)
