# Dust `put_new` / `if_absent` — Design + Implementation

**Date:** 2026-06-27
**Status:** Implemented (server + WS/HTTP, Elixir SDK, TypeScript SDK, Crystal CLI)
**Source:** single-flight-coordination feedback (#4a), rtsrc integration

## Goal

A first-class write precondition that succeeds only when the target key
does **not** already exist. Makes "claim a key that may not exist yet"
race-free and readable — the missing-revision case that `if_match:
<revision>` cannot express. The first concurrency primitive on the path
to leases / `Dust.once`, and broadly useful on its own.

## Semantics

- `Dust.put(store, path, value, if_absent: true)`:
  - key absent → write commits, returns `:ok`
  - key present → no write, returns `{:error, :exists}`
- **Leaf + `:set` only** (mirrors CAS scope):
  - `if_absent` on a non-`set` op → `{:error, :if_absent_unsupported_op}`
  - `if_absent` with a multi-leaf map value → `{:error, :if_absent_multi_leaf}`
- `if_absent` and `if_match` are **mutually exclusive** in one op →
  `{:error, :invalid_precondition}`.
- Existence is checked **inside the write transaction** against
  `store_entries`, identical in placement to the `if_match` revision check,
  so the claim is atomic against concurrent writers.

## Wire / capver

- Rides on **capver 3** (already current; `min_capver = 3`, pre-launch
  breaks freely) — no bump. `if_absent` is an additive optional write field.
- WS reply on conflict: `{error: {reason: "exists"}}`.
- HTTP: `If-None-Match: *` on `PUT /entries/...` means "only if absent";
  `412 Precondition Failed` with `{error: "exists"}` when present. Mirrors
  the existing `If-Match` → `412` path.

## Surfaces (mirror every `if_match` site)

- `server/lib/dust/sync.ex` — `validate_if_absent_attrs/1`, thread into
  `write/2` + `batch_write/2`, mutual-exclusion check.
- `server/lib/dust/sync/writer.ex` — `maybe_validate_if_absent/3`
  (existence check → `{:error, :exists}`) in `do_write`/`do_batch_write`
  transactions.
- `server/lib/dust_web/channels/store_channel.ex` — validate +
  `maybe_put_if_absent` + `"exists"` / precondition error replies.
- `server/lib/dust_web/controllers/api/entries_api_controller.ex` —
  `If-None-Match: *` → `if_absent`; `412` conflict schema reuse.
- `protocol/spec/sync-semantics.md`, `protocol/spec/asyncapi.yaml`,
  `protocol/elixir/lib/dust_protocol.ex` — document the field.
- `sdk/elixir`: `sync_engine.ex` (`maybe_put_if_absent`, `reason_to_atom("exists")`),
  `connection.ex` (`maybe_put_if_absent`).
- `sdk/typescript/src/dust.ts` — `put(..., { ifAbsent: true })`,
  `payload.if_absent`, `ExistsError` (or `{ reason: "exists" }` detection).
- `cli/src/dust/commands/data.cr` — `dust put ... --if-absent`.

## Out of scope

- Combining with leases (later phase).
- `committed_at` (deferred separately).
- Non-leaf / subtree claims.
