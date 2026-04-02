# Phase 4B Completion: DX Features + Capability Versioning

The SQLite-per-store migration changed how export, clone, and diff work. This design covers the remaining Phase 4B items, updated for the new architecture.

## 1. Store Export

Two formats. JSONL is the default (interop). SQLite binary is the fast path for backups and Dust-to-Dust transfers.

### JSONL Export

`dust export org/store > backup.jsonl`

Streams materialized entries, one JSON object per line. First line is metadata:

```json
{"_header": true, "store": "org/store", "seq": 847, "entry_count": 234, "exported_at": "2026-04-02T12:00:00Z"}
```

Each subsequent line is an entry:

```json
{"path": "users.alice.name", "value": "Alice", "type": "string"}
```

**Server endpoint:** `GET /api/stores/:org/:store/export?format=jsonl`
Streamed response. Bearer token auth. No size limit.

### SQLite Binary Export

`dust export org/store --format=sqlite > backup.db`

Uses `VACUUM INTO` to produce a standalone DB file. Includes the full op log, entries, and snapshots. Self-contained — open it with any SQLite client.

**Server endpoint:** `GET /api/stores/:org/:store/export?format=sqlite`
Streamed binary response. `Content-Type: application/x-sqlite3`.

### Default

JSONL. The SQLite format is opt-in via `--format=sqlite`.

## 2. Store Import

`dust import org/store < backup.jsonl`

JSONL only. Reads lines, writes each as a `set` op through the normal write path. Each entry gets a new seq. Overwrites existing keys (LWW — import is "later"). Batched in groups of 100.

**Server endpoint:** `POST /api/stores/:org/:store/import`
Streaming request body. Returns:

```json
{"ok": true, "entries_imported": 234}
```

No SQLite import. If you have a SQLite backup, use clone.

## 3. Store Clone

Server-side operation. No data crosses the wire to the client.

`dust clone org/store org/new-store`

**Flow:**
1. Validate target name doesn't exist. Check billing limits (store count).
2. Create new store metadata row in Postgres.
3. `VACUUM INTO` the new store's SQLite path.
4. Scan the cloned DB for file entries (`type = 'file'`). Increment blob `reference_count` for each referenced hash.
5. Return `{ok: true, store: %{name, id}}`.

**Server endpoint:** `POST /api/stores/:org/:store/clone`
Body: `{"name": "new-store-name"}`

Synchronous. The SQLite copy is near-instant. The refcount scan may take seconds for stores with thousands of file entries. Move to Oban if this becomes a problem.

**Edge cases:**
- Safe during concurrent writes — `VACUUM INTO` reads a consistent WAL snapshot.
- Preserves the full op log and snapshots (byte-level DB copy).
- The cloned store gets a new `store_id` in Postgres but inherits seq numbers from the source.

## 4. Time-Travel Diff

`dust diff org/store --from-seq 40 --to-seq 80`

Shows what changed between two sequence points. If `--to-seq` is omitted, defaults to current seq.

**Server endpoint:** `GET /api/stores/:org/:store/diff?from_seq=N&to_seq=M`

**How it works:**

Fetches ops in the range from SQLite. Computes "before" state at `from_seq` and "after" state at `to_seq` by replaying ops against the latest snapshot.

Response:

```json
{
  "from_seq": 40,
  "to_seq": 80,
  "changes": [
    {"path": "users.alice.name", "op": "set", "before": null, "after": "Alice"},
    {"path": "users.bob", "op": "delete", "before": {"name": "Bob"}, "after": null},
    {"path": "stats.views", "op": "increment", "before": 10, "after": 47}
  ]
}
```

**Compaction boundary:** If `from_seq` falls before the latest snapshot, return `{:error, :compacted, %{earliest_available: snapshot_seq}}`. The CLI prints the earliest available seq.

**CLI output:** Colorized terminal diff by default. `--json` for machine-readable output.

## 5. Rich Status with Live Refresh

`dust status` prints a one-shot snapshot. `dust status --watch` (or `-w`) refreshes in place every 2 seconds via ANSI escape codes.

**Display:**

```
Store: james/blog
Connection: connected (ws://localhost:7755)
Seq: 847 (server) / 847 (local cache)
Entries: 234
Ops: 12,403
Last compaction: seq 10000 (2026-03-30 14:22 UTC)
Storage: 1.2 MB (sqlite) / 340 KB (files)

Recent ops (last 5):
  #847  set        posts.new-post.title   "Hello World"     2s ago
  #846  set        posts.new-post.draft   true              2s ago
  #845  delete     posts.old-draft        -                 5m ago
  #844  increment  stats.views            42 → 43           12m ago
  #843  merge      config                 {3 keys}          1h ago
```

**Data source:** New `"status"` request/reply on the store channel. The server reads from Postgres cached metadata (entry_count, op_count, current_seq, file_storage_bytes), SQLite file size on disk, latest snapshot row, and last 5 ops. Returns everything in one payload. Reuses the existing WebSocket connection — no separate REST endpoint.

**Live mode:** The CLI sends a `"status"` push every 2 seconds and redraws the terminal output in place.

## 6. Capability Versioning

Tailscale-style: client declares its version, server adapts.

### Protocol Lib

`DustProtocol` defines:

```elixir
@current_capver 1
@min_capver 1

# Capability version history
# 1: Initial protocol — JSON wire format, all current op types
```

### Socket Connect

`StoreSocket` already receives `capver` from the client. Add enforcement:

- If client `capver < @min_capver` → reject: `{:error, %{reason: "upgrade_required", min_capver: @min_capver}}`
- If client `capver` is missing or unparseable → treat as 1 (backward compat for existing clients)

### Join Reply

Include `%{capver: @current_capver, capver_min: @min_capver}` in the join reply. The client learns what the server speaks.

### Server Response Adaptation

When broadcasting events, the server can check recipient capver before sending event types added in later versions. For capver 1 this is a no-op. The mechanism activates in Phase 4C when agent presence events arrive.

### CLI/SDK

Already sending `capver: "1"`. On rejection, print: "Your client is outdated. Please upgrade to continue."

## Implementation Order

1. Capability versioning (small, unblocks future protocol changes)
2. Export (JSONL + SQLite binary)
3. Import (JSONL)
4. Clone
5. Diff
6. Rich status with live refresh

Export before clone because clone's SQLite path already exists in `StoreDB.export/2`. Import before clone because clone is self-contained. Diff before status because the op-replay logic in diff is reusable. Status last because it touches the most surface area (new channel event + CLI TUI).

## Deferred

- Store-vs-store diff (needs cross-server logic for staging/prod comparison)
- MessagePack wire format (pair with TypeScript SDK in Phase 4C)
- CapMap / per-org feature flags (Phase 4C+ when needed)
