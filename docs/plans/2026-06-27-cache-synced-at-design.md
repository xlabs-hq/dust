# Dust Cache `synced_at` — Design

**Date:** 2026-06-27
**Status:** Implemented (Elixir SDK, TypeScript SDK, Crystal CLI)

## Motivation

Adopter feedback (v0.1): the `dust_cache` row carries no wall-clock
timestamp, so freshness cannot be inferred from the row — adopters are
forced to embed a `last_fetched_at` inside the stored value. The cache
row's `seq` is a logical clock, not wall time, so it cannot answer "how
stale is my local copy of this key."

## Decision

Add a single nullable column, `synced_at`, to the local cache row across
every SDK that maintains a `dust_cache` table.

- **Semantics:** local wall-clock at the moment *this* mirror wrote the
  row from a sync/webhook event. Unix epoch **milliseconds**, integer.
- **Not** server commit time. A server `committed_at` would be
  authoritative and identical across mirrors but requires a protocol
  change + capver bump + write-path changes in every SDK. Rejected for
  this increment; `synced_at` answers the adopter's actual question
  (mirror freshness, cold-start staleness) with zero wire changes.
- Stamped inside each cache adapter's write path, so the
  `Dust.Cache` `write/6` and `write_batch/3` callback signatures do not
  change — the adapter calls its own clock.

## Surface

- `Dust.Entry` gains a `synced_at` field.
- Read via `Dust.entry/2` (the existing metadata read).
- **Leaf-only this increment.** Subtree-assembled entries report
  `synced_at: nil`. This mirrors the leaf-only CAS precedent: subtree
  freshness (max-descendant `synced_at`) is computable later if a real
  use case appears, but it would expand the `read_subtree` contract for
  no current demand.
- `enum/3`/`range/4` projections are unchanged — they return
  materialized values, not entries. Surfacing freshness in list
  projections is a possible follow-up, deferred.

## Cross-SDK parity

Per the standing cache-schema-parity rule, the column lands in every
SDK that mirrors the store, with identical name and meaning:

- Elixir SDK — `Dust.Cache.Memory` (parallel `synced` map keyed by
  `{store, path}`) and `Dust.Cache.Ecto` (real `synced_at` column).
- TypeScript SDK — `MemoryCache` + persistent cache schema.
- Crystal CLI — `dust_cache` SQLite column.

Only `read_entry` changes contract (returns `{value, type, seq,
synced_at}`); all other read paths are untouched.

## Migration

- `Dust.Cache.Ecto.Migration.up/0` creates the column on fresh installs.
- The column is **nullable**: existing rows (and subtree reads) read back
  `nil` rather than failing.
- Existing adopters must add the column before upgrading the library:

  ```elixir
  alter table(:dust_cache) do
    add :synced_at, :bigint
  end
  ```

  Documented in the SDK README/CHANGELOG.

## Non-goals (unchanged)

- per-key TTL / eviction (separate, larger design)
- server-authoritative `committed_at`
- freshness in `enum`/`range` list projections
