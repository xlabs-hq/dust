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

## Cross-Store Queries (Admin + Billing)

Admin dashboard needs aggregate stats. The Postgres `stores` table gets cached metadata columns updated by the Writer after each write:

- `entry_count` — leaf entry count (for billing + dashboard)
- `op_count` — total ops written (for dashboard + compaction trigger)
- `current_seq` — latest store_seq (for dashboard)
- `file_storage_bytes` — sum of blob sizes referenced by this store (for billing)

The Writer updates these via a single Postgres `UPDATE stores SET ...` after each write transaction. This is one indexed update to Postgres per write — cheap.

**Admin pages that do cross-store queries** (dashboard totals, global ops list, store detail with ops/entries) will need changes:
- Dashboard totals: `SELECT sum(entry_count), sum(op_count) FROM stores WHERE org_id = ?` — Postgres only
- Stores list with stats: already from `stores` table metadata
- Global ops view: query individual store SQLite files on demand (paginated, not all at once). Or deprecate the global ops view in favor of per-store ops.
- Store detail entries/ops: open read connection to that store's SQLite

**Billing/auth paths moving off Postgres:**
- `Files.store_usage_bytes/1` — currently joins blobs to store_entries in Postgres. Replaced by cached `file_storage_bytes` column on `stores` table (updated by Writer on put_file/delete).
- `Sync.has_file_ref?/2` — currently queries store_entries in Postgres for file download authorization. Replaced by opening a read connection to the store's SQLite: `SELECT 1 FROM store_entries WHERE type = 'file' AND json_extract(value, '$.hash') = ?`.

## Compaction

Moves inside the Writer GenServer. Oban job sends `{:compact, retention_days}` cast to the Writer. The Writer does snapshot + delete + VACUUM in one place. No cross-process race condition.

## Store Lifecycle

**Create:** Postgres metadata row. SQLite file created **eagerly** via `StoreDB.ensure_created(store_id)` at store creation time. This avoids the empty-store regression where UI show pages and channel joins read from a nonexistent DB.

**Delete:** Soft-delete in Postgres. Oban cleanup job:
1. Stop the Writer GenServer if running
2. Scan SQLite store_entries for file refs, decrement blob reference_counts
3. Delete the SQLite file
4. Clean up orphaned blobs with reference_count <= 0

**Backup:** Use SQLite's online backup API (`sqlite3_backup_init`) rather than raw file copy. A live WAL DB may have uncommitted pages in the WAL file — raw copy can produce a corrupt backup. Exqlite doesn't expose the backup API directly, so wrap it: `Exqlite.query(conn, "VACUUM INTO ?", [dest_path])` copies to a standalone file safely.

**Export:** Two options:
- Binary: `VACUUM INTO` to a temp file, stream that file over HTTP. Self-contained SQLite DB.
- JSONL: read entries from SQLite, stream as JSON lines. For interop with non-SQLite consumers.

**Clone:** `VACUUM INTO` the new store's path + new Postgres metadata row. Then scan the cloned DB for file entries and increment blob reference_counts for each referenced hash. Not instant for stores with many file refs, but the file copy itself is fast.

## Empty Store Contract

`StoreDB.read_conn(store_id)` returns `{:ok, conn}` if the file exists, `{:error, :not_found}` if it doesn't. All read paths handle the not-found case by returning empty results (no entries, no ops, seq = 0). This is equivalent to "the store exists in Postgres but has no data yet."

The channel join path already handles seq = 0 and empty catch-up. The store show UI needs to handle "no entries" gracefully (it likely does already via empty lists).

## Test Strategy

- Temp store data dir per test run (`System.tmp_dir!/dust_test_{random}`)
- Each test's store gets its own SQLite file naturally
- File deletion = cleanup (no sandbox needed for store data)
- Postgres sandbox stays for accounts/tokens metadata

**Required test coverage:**
- Migration parity: create store in Postgres, migrate, verify reads + rollback floor + seq continuity
- File lifecycle: clone/delete/export with put_file entries — verify blob refcounts increment/decrement correctly
- Empty store: UI show, channel join, dust_status before first write
- Billing/auth after migration: file download authorization via SQLite, file-storage limit checks via cached column

## Implementation Order

1. Add Exqlite dep, create StoreDB module (path, read_conn, ensure_created, empty-store contract)
2. Add cached metadata columns to Postgres stores table (migration)
3. Rewrite Writer to use SQLite (biggest change)
4. Rewrite Sync read functions to use SQLite (get_entry, get_ops_since, etc.)
5. Rewrite has_file_ref and store_usage_bytes for SQLite
6. Rewrite Rollback to use SQLite
7. Update Compaction to message Writer
8. Update channel catch-up to use SQLite reads
9. Update admin LiveViews for new data model
10. Update tests (all categories above)
11. Migration Mix task (Postgres → SQLite)
12. Drop old Postgres store tables

## Deferred

- MessagePack wire format (Phase 4C+)
- Capability versioning negotiation (Phase 4C+)
- Ed25519 store signing (Phase 5)
