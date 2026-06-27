# Phase 5 — CAS via `if_match` Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Subagents implement + test + report; the main session commits. Strict TDD per task.

**Goal:** Ship optimistic concurrency writes (`if_match: revision`) across the server, all three SDKs (Elixir, TS, Crystal CLI), the wire protocol, and a new `PUT /api/stores/:org/:store/entries/*path` HTTP endpoint. Leaf `set` ops only, behind capver=2.

**Architecture:** Extend the existing server-side `sqlite_transaction` in `Dust.Sync.Writer` with a pre-INSERT seq check when `if_match` is present. The read-compare-write happens inside one SQLite transaction, so there's no TOCTOU race. Clients negotiate capver=2 on WebSocket join and get CAS support; old clients (capver=1) can't send `if_match` and never receive conflict errors. A new HTTP `PUT` endpoint with `If-Match` header parity is added alongside the WebSocket path so Ruby/Python SDKs can use CAS when they're built.

**Tech stack:** Same as Phases 1-4. First phase that touches the wire protocol, the server write path, and capver negotiation.

**Design reference:** `docs/plans/2026-04-13-kv-native-features-design.md` — "CAS Writes" section. Project memory `project_cas_scope.md` confirms: leaf-only, capver=2, subtree CAS deferred.

---

## Background the engineer needs

### What the recon found (pinned facts)

1. **Wire shape:** Write events are Phoenix channel pushes with payload `%{"op", "path", "value", "client_op_id"}` (string keys). Reply is `{:ok, %{store_seq: N}}` or `{:error, %{reason: string}}`. Adding an optional `"if_match"` field is a strict addition — msgpack/JSON both handle it transparently.

2. **Server write pipeline:**
   - `DustWeb.StoreChannel.handle_in("write", ...)` (store_channel.ex:53-68)
   - → `handle_write_op/2` validates op, path, value, billing (store_channel.ex:188-227)
   - → `Dust.Sync.write/2` (sync.ex:5-16)
   - → `Dust.Sync.Writer.write/2` (writer.ex:80-140) — **this runs inside `sqlite_transaction`**
   - Inside the transaction: reads `max(store_ops.seq, store_snapshots.seq)`, computes `next_seq`, INSERTs into `store_ops`, applies to `store_entries` via `upsert_entry` (writer.ex:266-274).

3. **Seq semantics:** Every entry has a `seq` column holding the store-wide monotonic seq assigned at its write. `Dust.Sync.get_entry/2` already returns it (sync.ex:61-76). CAS validation is: read current seq inside the transaction, compare to `if_match`, proceed or abort.

4. **Capver today:** `@current_capver 1` hardcoded in `protocol/elixir/lib/dust_protocol.ex:6`. Clients send capver in the join query param. Server returns `capver` and `capver_min` on join response (store_channel.ex:44-45). **No validation or feature gating today — capver is purely informational.**

5. **Existing error shape:** `{:error, %{reason: "rate_limited" | "unauthorized" | "invalid_op" | ...}}`. New `:conflict` reason fits cleanly. Elixir SDK already has `handle_write_rejected` wired up (connection.ex:176-197 → sync_engine.ex).

6. **HTTP write endpoints today:** `POST /import` and `POST /clone` only. **No single-entry PUT exists** — Phase 5 adds the first one. Auth pattern is `DustWeb.Plugs.ApiTokenAuth` via `:api_auth` pipeline, mirrored by existing controllers.

### Design decisions pinned down

These are non-negotiable for this phase. If any task's subagent wants to deviate, they must stop and report.

1. **Only `set` (put) ops support `if_match` in Phase 5.** `delete`, `merge`, `increment`, `add`, `remove`, `put_file` all reject `if_match` if present. Most common CAS use case is "edit this field optimistically" — covered by `set`. The others can be added in later phases.

2. **Only leaf values.** `set("users.alice", %{name: "a"})` with a dict value flattens to multiple leaves and can't be CAS'd atomically without a subtree index (which we deferred). Server rejects `if_match` on set ops where the value is a dict.

3. **`if_match` is a positive integer.** No `0` sentinel for "must not exist," no `:*` wildcard. If you want "create only if absent," use a unique path and trust LWW. The simpler API is worth the reduced flexibility.

4. **Missing path + `if_match` set = conflict.** If the client sends `if_match: N` for a path that doesn't exist, the server returns `{:error, :conflict}`. (Symmetric to the "seq doesn't match" case — the precondition "this entry exists with seq N" is false.)

5. **Capver=2 is required to send `if_match`.** Server rejects `if_match` from capver=1 clients with `{:error, %{reason: "capver_mismatch"}}`. This prevents silent downgrade.

6. **HTTP endpoint:**
   - `PUT /api/stores/:org/:store/entries/*path`
   - Body: raw JSON value (not an envelope). Request `Content-Type: application/json`.
   - Optional header `If-Match: <revision>`. Integer string.
   - Response on success: `200 OK` with `{"revision": N, "store_seq": N}` (they're the same value, we return both for clarity).
   - Response on conflict: `412 Precondition Failed` with `{"error": "conflict", "current_revision": N | null}`.
   - Response on other errors: 4xx with `{"error": reason}` following existing controller conventions.
   - Capver is NOT a concept on HTTP. The endpoint is implicitly capver-2 — if you're calling it, you know CAS exists.

7. **Wire reply shape for conflict:**
   - WebSocket: `{:error, %{reason: "conflict", current_revision: N | nil}}`
   - Elixir SDK translates to: `{:error, :conflict}`
   - TS SDK translates to: `Promise.reject(new ConflictError(current_revision))` or similar
   - Crystal CLI: prints `{"error": "conflict"}` to stderr, exits non-zero

---

## Scope

**In scope:**

1. Bump `@current_capver` from 1 to 2
2. Protocol spec updates (`asyncapi.yaml`, `sync-semantics.md`) — document `if_match` field and conflict error
3. Server `Dust.Sync.Writer` CAS validation inside the transaction
4. Server `StoreChannel.handle_write_op` forwards `if_match` and rejects multi-leaf / non-set ops
5. New HTTP endpoint `PUT /api/stores/:org/:store/entries/*path` with `If-Match` support
6. Elixir SDK: connection bumps to capver=2
7. Elixir SDK: `Dust.put/4` with `if_match:` option, handles conflict reply
8. TS SDK: connection bumps to capver=2
9. TS SDK: `Dust.put` with `{ ifMatch }` option, handles conflict
10. Crystal CLI: `dust put --if-match N` flag
11. Final verification

**Out of scope:**

- CAS on `delete`, `merge`, `increment`, `add`, `remove`, `put_file` (any op other than `set`)
- CAS on dict-value `set` (multi-leaf)
- Subtree CAS (explicitly deferred per `project_cas_scope.md`)
- "Must not exist" semantics (`if_match: 0` / `if_none_match: :*`)
- Ruby/Python SDK implementations (HTTP endpoint is ready for them; the SDKs themselves are separate work)
- Capver re-negotiation mid-session or graceful downgrade (we control both sides; server rejects mismatch)

---

## Task list

### Task 1: Protocol spec — bump capver, document `if_match`

**Files:**
- Modify: `protocol/elixir/lib/dust_protocol.ex`
- Modify: `protocol/spec/asyncapi.yaml`
- Modify: `protocol/spec/sync-semantics.md`
- Modify: any protocol-level tests in `protocol/elixir/test/`

**Step 1: Bump capver** in `protocol/elixir/lib/dust_protocol.ex`:

```elixir
@current_capver 2
# @min_capver stays at 1 — the server still accepts capver=1 joins for reads
```

**Step 2: Update `asyncapi.yaml`** to document the new `if_match` optional field in the write message schema and the new `conflict` reply variant.

**Step 3: Update `sync-semantics.md`** with a new "Compare-and-swap writes" section describing:
- `if_match` is an optional integer on write payloads for `set` ops
- If present, the server validates the current entry's `seq` matches before writing
- Stale writes return `{:error, reason: "conflict", current_revision: N | null}`
- Only `set` ops and leaf values are supported
- Requires capver >= 2

**Step 4: Any existing protocol tests** — bump capver expectations from 1 to 2. Search for `capver` / `current_capver` in test files.

**Step 5: Verify compile**

```bash
cd protocol/elixir && mix compile
```

**Step 6: Commit**

Message: `feat(protocol): bump capver to 2 and document if_match CAS writes`

---

### Task 2: Server `Dust.Sync.Writer` — CAS validation inside the transaction

**Files:**
- Modify: `server/lib/dust/sync/writer.ex`
- Modify: `server/lib/dust/sync.ex` (the `write/2` entry point may need to accept `if_match`)
- Modify or create: `server/test/dust/sync/writer_test.exs` OR add to existing `server/test/dust/sync_test.exs`

**Step 1: Failing tests**

Add tests to whichever sync-test file is most appropriate (`sync_test.exs` already exists from Phase 2 Task 7):

```elixir
describe "CAS writes" do
  test "set with matching if_match succeeds" do
    store = create_test_store()
    :ok = Dust.Sync.write(store.id, %{op: "set", path: "k", value: 1, device_id: "d", client_op_id: "c1"})
    %{seq: seq} = Dust.Sync.get_entry(store.id, "k")

    assert {:ok, %{store_seq: _}} =
             Dust.Sync.write(store.id, %{
               op: "set",
               path: "k",
               value: 2,
               device_id: "d",
               client_op_id: "c2",
               if_match: seq
             })

    assert %{value: 2} = Dust.Sync.get_entry(store.id, "k")
  end

  test "set with stale if_match returns :conflict" do
    store = create_test_store()
    :ok = Dust.Sync.write(store.id, %{op: "set", path: "k", value: 1, device_id: "d", client_op_id: "c1"})
    %{seq: stale_seq} = Dust.Sync.get_entry(store.id, "k")

    # Bump the seq with another write
    :ok = Dust.Sync.write(store.id, %{op: "set", path: "k", value: 2, device_id: "d", client_op_id: "c2"})

    assert {:error, :conflict} =
             Dust.Sync.write(store.id, %{
               op: "set",
               path: "k",
               value: 3,
               device_id: "d",
               client_op_id: "c3",
               if_match: stale_seq
             })

    # Verify the entry was NOT updated
    assert %{value: 2} = Dust.Sync.get_entry(store.id, "k")
  end

  test "set with if_match on a missing path returns :conflict" do
    store = create_test_store()
    assert {:error, :conflict} =
             Dust.Sync.write(store.id, %{
               op: "set",
               path: "missing",
               value: 1,
               device_id: "d",
               client_op_id: "c1",
               if_match: 42
             })
  end

  test "set without if_match is LWW as before" do
    store = create_test_store()
    :ok = Dust.Sync.write(store.id, %{op: "set", path: "k", value: 1, device_id: "d", client_op_id: "c1"})
    assert {:ok, _} = Dust.Sync.write(store.id, %{op: "set", path: "k", value: 2, device_id: "d", client_op_id: "c2"})
    assert %{value: 2} = Dust.Sync.get_entry(store.id, "k")
  end
end
```

(Exact `create_test_store` / helper names depend on the existing test setup — check `server/test/dust/sync_test.exs` for the pattern.)

**Step 2: Run — FAIL.**

**Step 3: Implement** in `Dust.Sync.Writer.write/2`:

Inside `sqlite_transaction`, after computing `next_seq` but **before** the INSERT into `store_ops`:

```elixir
if if_match = attrs[:if_match] || attrs["if_match"] do
  case query_one_row(db, "SELECT seq FROM store_entries WHERE path = ?", [path]) do
    [current_seq] when current_seq == if_match ->
      :ok  # matches, proceed

    [_other_seq] ->
      raise Dust.Sync.Writer.ConflictError  # tagged, caught below

    nil ->
      raise Dust.Sync.Writer.ConflictError  # path doesn't exist
  end
end
```

Catch the `ConflictError` at the outer `sqlite_transaction` level (or inside `write/2`) and return `{:error, :conflict}`. The transaction rolls back, nothing is written, no seq is consumed.

Alternative (preferred, avoids `raise`): use a `with` chain:

```elixir
with :ok <- maybe_validate_if_match(db, path, attrs) do
  # existing INSERT logic
end
```

Where `maybe_validate_if_match/3`:

```elixir
defp maybe_validate_if_match(_db, _path, %{if_match: nil}), do: :ok
defp maybe_validate_if_match(_db, _path, attrs) when not is_map_key(attrs, :if_match) and not is_map_key(attrs, "if_match"), do: :ok
defp maybe_validate_if_match(db, path, attrs) do
  expected = attrs[:if_match] || attrs["if_match"]
  case query_one_row(db, "SELECT seq FROM store_entries WHERE path = ?", [path]) do
    [^expected] -> :ok
    _ -> {:error, :conflict}
  end
end
```

Then the outer `write/2` returns `{:error, :conflict}` if `maybe_validate_if_match/3` fails, and the caller (`Dust.Sync.write/2`) propagates it up. **No `raise`, no `try/rescue` — just `with` chains.** The project memory `feedback_no_try_rescue.md` applies.

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(server): Dust.Sync.Writer validates if_match inside the transaction`

---

### Task 3: Server `StoreChannel.handle_write_op` — forward `if_match`, reject multi-leaf/non-set ops

**Files:**
- Modify: `server/lib/dust_web/channels/store_channel.ex`
- Modify: `server/test/dust_web/channels/store_channel_test.exs` (if it exists) or add a new test

**Step 1: Failing tests**

Add channel-level tests that:
- Push a write with `if_match` on capver=2 channel → success
- Push a write with `if_match` on capver=1 channel → error reason "capver_mismatch"
- Push a write with `op: "set"` and dict value + `if_match` → error reason "if_match_multi_leaf"
- Push a write with `op: "increment"` + `if_match` → error reason "if_match_unsupported_op"
- Push a write with `if_match` when entry is stale → error reason "conflict"

Match whatever channel test fixtures exist today.

**Step 2: Run — FAIL.**

**Step 3: Implement**

In `handle_write_op/2` (store_channel.ex:188-227), extract `if_match` from params if present. Before calling `Dust.Sync.write`:

1. Check the join's capver is >= 2 (socket assigns — look at where capver is stored on `join/3`). If not, reply `{:error, %{reason: "capver_mismatch"}}`.
2. Check `op` is `"set"`. If not, reply `{:error, %{reason: "if_match_unsupported_op", op: op}}`.
3. Check `value` is not a dict/map. If it is, reply `{:error, %{reason: "if_match_multi_leaf"}}`.
4. Forward `if_match` to `Dust.Sync.write/2` by adding it to the attrs map.

The conflict case is handled by the Writer returning `{:error, :conflict}` — just wrap that as `{:error, %{reason: "conflict"}}` in the reply.

**Capver on join:** Look at `StoreChannel.join/3`. It probably stores `capver` in `socket.assigns`. If not, add it: `assign(socket, :capver, params["capver"] || 1)`.

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(server): StoreChannel forwards if_match and gates CAS on capver=2`

---

### Task 4: HTTP `PUT /api/stores/:org/:store/entries/*path` with `If-Match`

**Files:**
- Modify: `server/lib/dust_web/controllers/api/entries_api_controller.ex` — add `put/2` action
- Modify: `server/lib/dust_web/router.ex` — add the route
- Modify: `server/test/dust_web/controllers/api/entries_api_controller_test.exs`

**Step 1: Failing tests**

```elixir
describe "PUT /api/stores/:org/:store/entries/*path" do
  test "writes a leaf value without If-Match (LWW)", %{conn: conn, org: org, store: store} do
    conn = conn
      |> put_req_header("content-type", "application/json")
      |> put(~p"/api/stores/#{org.slug}/#{store.name}/entries/users.alice.name", ~s("Alice"))

    body = json_response(conn, 200)
    assert is_integer(body["revision"])
  end

  test "writes a leaf value with matching If-Match succeeds", %{conn: conn, org: org, store: store} do
    # Seed
    Dust.Sync.write(store.id, %{op: "set", path: "k", value: 1, device_id: "d", client_op_id: "c1"})
    %{seq: seq} = Dust.Sync.get_entry(store.id, "k")

    conn = conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("if-match", Integer.to_string(seq))
      |> put(~p"/api/stores/#{org.slug}/#{store.name}/entries/k", "2")

    body = json_response(conn, 200)
    assert body["revision"] > seq
  end

  test "stale If-Match returns 412", %{conn: conn, org: org, store: store} do
    Dust.Sync.write(store.id, %{op: "set", path: "k", value: 1, device_id: "d", client_op_id: "c1"})

    conn = conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("if-match", "999999")
      |> put(~p"/api/stores/#{org.slug}/#{store.name}/entries/k", "2")

    body = json_response(conn, 412)
    assert body["error"] == "conflict"
  end

  test "returns 401 without Bearer token", %{org: org, store: store} do
    conn = build_conn()
      |> put_req_header("content-type", "application/json")
      |> put(~p"/api/stores/#{org.slug}/#{store.name}/entries/k", "1")

    assert response(conn, 401)
  end
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

Add route in `router.ex` **BEFORE** the existing `get "/stores/:org/:store/entries/*path"` wildcard (or the PUT might be caught by the GET wildcard depending on Phoenix routing rules — test and adjust):

```elixir
put "/stores/:org/:store/entries/*path", EntriesApiController, :put
```

Add the action in `entries_api_controller.ex`:

```elixir
def put(conn, %{"path" => path_segments} = params) do
  path = Enum.join(path_segments, ".")

  with {:ok, value} <- read_json_body(conn),
       {:ok, store} <- fetch_store(conn, params),
       :ok <- verify_write_permission(conn.assigns.store_token),
       attrs <- build_write_attrs(path, value, conn),
       {:ok, result} <- Dust.Sync.write(store.id, attrs) do
    json(conn, %{"revision" => result.store_seq, "store_seq" => result.store_seq})
  else
    {:error, :conflict} ->
      current = current_revision(store, path)
      conn |> put_status(412) |> json(%{"error" => "conflict", "current_revision" => current})

    {:error, {:invalid_params, detail}} ->
      conn |> put_status(400) |> json(%{"error" => "invalid_params", "detail" => detail})

    # ... reuse existing error renderers from index/show/batch ...
  end
end

defp read_json_body(conn) do
  case Plug.Conn.read_body(conn) do
    {:ok, body, _conn} ->
      case Jason.decode(body) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, {:invalid_params, "body must be valid JSON"}}
      end

    _ ->
      {:error, {:invalid_params, "missing body"}}
  end
end

defp build_write_attrs(path, value, conn) do
  attrs = %{
    op: "set",
    path: path,
    value: value,
    device_id: "http:" <> conn.assigns.store_token.id,
    client_op_id: conn.req_headers |> List.keyfind("x-request-id", 0) |> elem(1) || generate_op_id()
  }

  case get_req_header(conn, "if-match") do
    [value] ->
      case Integer.parse(value) do
        {int, ""} -> Map.put(attrs, :if_match, int)
        _ -> attrs  # malformed If-Match — ignore or 400? For now ignore (LWW)
      end

    _ ->
      attrs
  end
end

defp current_revision(store, path) do
  case Dust.Sync.get_entry(store.id, path) do
    %{seq: seq} -> seq
    nil -> nil
  end
end
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(server): PUT /api/stores/:org/:store/entries/*path with If-Match`

---

### Task 5: Elixir SDK — bump capver to 2

**Files:**
- Modify: `sdk/elixir/lib/dust/connection.ex`
- Modify: `sdk/elixir/test/dust/connection_test.exs` (if capver is tested)

**Step 1: Change** `capver: "1"` to `capver: "2"` in the WebSocket URL query params (connection.ex:54-55 per recon).

**Step 2: Any existing test** that asserts the SDK sends capver=1 needs updating.

**Step 3: Run** `mix test test/dust/connection_test.exs` and full `mix test`.

**Step 4: Commit**

Message: `feat(sdk): Dust connection negotiates capver=2`

---

### Task 6: Elixir SDK — `Dust.put/4` with `if_match`

**Files:**
- Modify: `sdk/elixir/lib/dust.ex`
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Modify: `sdk/elixir/lib/dust/connection.ex` (the write payload builder)
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs`

**Step 1: Failing tests**

```elixir
test "put with matching if_match succeeds" do
  store = "test/store"
  Dust.SyncEngine.seed_entry(store, "k", 1, "integer")
  {:ok, entry} = Dust.SyncEngine.entry(store, "k")

  # Note: can't easily test real writes in the SDK unit test without a mock server.
  # Check the existing test pattern — there may be a mock Connection that records pushes.
  # If the test is "verify the push payload contains if_match", that's sufficient.
  ...
end
```

If the existing SDK tests use a mock connection that records pushes, assert that the push payload contains `if_match: N` when the option is set. If the tests require a real server, this task's test coverage is just a push-payload check; real E2E coverage comes from Task 11 (integration tests) or manual smoke.

**Step 2: Implementation**

Extend the `put` chain:

- `Dust.put(store, path, value, opts \\ [])` — new arity-4 overload in `dust.ex`
- `Dust.SyncEngine.put(store, path, value, opts)` — accepts `:if_match` in opts
- Connection's write payload builder — adds `"if_match"` key to the payload if `opts[:if_match]` is set
- Server reply handling — when the reply is `{:error, %{reason: "conflict"}}`, surface as `{:error, :conflict}` back to the caller

Check how the existing `put/3` handles the reply. The synchronous `put` returns `:ok` on success today. For CAS, it should return `{:ok, store_seq}` on success and `{:error, :conflict}` on conflict. That's a return-shape change — decide whether it's OK to change or whether you need a new method name.

**Decision:** `put/3` keeps its `:ok`/`{:error, _}` shape. `put/4` with `if_match` returns `{:ok, store_seq}` on success and `{:error, :conflict}` on conflict. The arity distinguishes them.

Actually, simpler: **`put/3` returns `:ok | {:error, reason}`, `put/4` returns `{:ok, store_seq} | {:error, :conflict | other}`**. Overload by arity.

Even simpler: just make `put` always return `{:ok, store_seq}` and `{:error, reason}`. That's a small breaking change for existing `put/3` callers but the TS SDK already does this (returns `{storeSeq}`). Consistent shape across SDKs is worth it.

**Pin this decision in the plan:** Elixir `Dust.put/3` and `Dust.put/4` both return `{:ok, store_seq :: integer}` or `{:error, reason}`. The arity-3 version stays LWW and never returns `:conflict`. The arity-4 version with `if_match:` may return `{:error, :conflict}`. Callers of the old `:ok`-returning `put/3` need to match on `{:ok, _}` instead of `:ok` — small breaking change, worth it.

**Step 3: Run — PASS.**

**Step 4: Commit**

Message: `feat(sdk): Dust.put/4 accepts :if_match and returns {:error, :conflict} on stale writes`

---

### Task 7: TS SDK — capver=2 + `Dust.put` with `{ ifMatch }`

**Files:**
- Modify: `sdk/typescript/src/connection.ts`
- Modify: `sdk/typescript/src/dust.ts`
- Modify: `sdk/typescript/src/types.ts` (maybe — `ConflictError` class or error type)
- Modify: `sdk/typescript/test/connection.test.ts` (capver test)
- Modify: `sdk/typescript/test/dust.test.ts` (put with ifMatch)

**Step 1: Capver bump** — change `vsn` negotiation in `connection.ts:170` or wherever capver is set from `1` to `2`. Look for the query param or join params that include `capver`.

**Step 2: Add `put` overloads / options.**

Current: `async put(store, path, value): Promise<{ storeSeq }>`

New: `async put(store, path, value, opts?: { ifMatch?: number }): Promise<{ storeSeq }>`

On stale write, the server replies with `{error: {reason: "conflict"}}`. The TS SDK throws an error. Either:
- `throw new ConflictError(currentRevision?)` — custom error class
- `throw new Error("conflict")` — plain error with a specific message

Pick the custom class for type safety. Export it from `types.ts` and `index.ts`.

**Step 3: Failing tests** — mirror the Elixir test plan. The TS SDK test infrastructure has a mock Connection (per earlier recon) — verify push payloads contain `if_match` and simulate conflict replies.

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): capver=2 and Dust.put with { ifMatch } option`

---

### Task 8: Crystal CLI — `dust put --if-match N`

**Files:**
- Modify: `cli/src/dust/commands/data.cr` — `put` command
- Modify: `cli/src/dust/cli.cr` — maybe usage text update
- Modify: `cli/src/dust/client/connection.cr` — capver bump to 2
- Modify: `cli/spec/` — add tests if a pattern exists

**Step 1: Bump capver** — `capver: "1"` → `"2"` in connection.cr query params.

**Step 2: Add `--if-match N` flag** to the `put` command parser. Forward the integer value as a new field in the WebSocket push payload.

**Step 3: Handle conflict response.** When the server replies with `{error: {reason: "conflict"}}`, print to stderr and exit non-zero:

```crystal
STDERR.puts %({"error":"conflict"})
exit 1
```

**Step 4: Run** `crystal tool format` on touched files. Run cache spec to confirm no regressions.

**Step 5: Commit**

Message: `feat(cli): dust put --if-match N for CAS writes`

---

### Task 9: End-to-end integration test (optional but recommended)

**Files:**
- Create or modify: `server/test/integration/cas_test.exs` OR add to existing integration tests

**Step 1: Write an end-to-end test** that boots the full server, connects a test client, and exercises:
- Write with no `if_match` — LWW, succeeds
- Write with correct `if_match` — succeeds, seq bumps
- Write with stale `if_match` — conflict, entry unchanged
- Concurrent: two writes with the same `if_match` — one wins, one conflicts

The concurrent case is the most interesting but may be hard to simulate in a single test process. If the existing test infrastructure has a "start a real channel" helper, use it. Otherwise test the non-concurrent cases and document the concurrent case as a manual smoke test.

**Step 2: Run — PASS.**

**Step 3: Commit**

Message: `test(server): end-to-end CAS test exercises success, conflict, and LWW paths`

---

### Task 10: Final verification

**Files:** none modified.

**Step 1:** Run targeted Elixir SDK tests:
```bash
cd sdk/elixir && mix test
```

**Step 2:** Run targeted server tests:
```bash
cd server && mix test test/dust_web/controllers/api/ test/dust/sync_test.exs test/dust_web/channels/store_channel_test.exs
```

**Step 3:** Run TS SDK tests:
```bash
cd sdk/typescript && npm test && npx tsc --noEmit
```

**Step 4:** Run Crystal CLI targeted tests:
```bash
cd cli && crystal spec spec/cache/sqlite_spec.cr && shards build
```

**Step 5:** `crystal tool format --check src/ spec/` (CI-matching check).

Expected: everything green, no regressions from prior phases.

**Step 6:** No commit needed.

---

## Verification checklist

- [ ] `@current_capver` is 2.
- [ ] `asyncapi.yaml` documents `if_match` + `conflict` reply.
- [ ] `sync-semantics.md` has a "Compare-and-swap writes" section.
- [ ] `Dust.Sync.Writer` validates `if_match` inside the transaction without `try`/`rescue`.
- [ ] Stale `if_match` returns `{:error, :conflict}` and the entry is NOT modified.
- [ ] Missing path + `if_match` = conflict.
- [ ] `StoreChannel` rejects `if_match` on non-`set` ops with `if_match_unsupported_op`.
- [ ] `StoreChannel` rejects `if_match` on dict-value set with `if_match_multi_leaf`.
- [ ] `StoreChannel` rejects `if_match` on capver=1 channels with `capver_mismatch`.
- [ ] `PUT /entries/*path` works with and without `If-Match`.
- [ ] Stale `If-Match` returns 412 with `{"error": "conflict", "current_revision": N}`.
- [ ] Elixir SDK `Dust.put/4` accepts `:if_match` and surfaces `{:error, :conflict}`.
- [ ] TS SDK `Dust.put` accepts `{ ifMatch }` and throws `ConflictError` on conflict.
- [ ] Crystal CLI `dust put --if-match N` exits non-zero on conflict.
- [ ] No `try`/`rescue` added anywhere.
- [ ] All prior phase tests still pass.
- [ ] Crystal format check clean (CI parity).

## Cross-SDK parity check

- Elixir: `Dust.put(store, path, value, if_match: N)` → `{:ok, store_seq} | {:error, :conflict}`
- TypeScript: `Dust.put(store, path, value, { ifMatch: N })` → `{storeSeq}` or throws `ConflictError`
- Crystal CLI: `dust put store path value --if-match N` → exits 0 or 1 with JSON error
- HTTP: `PUT /entries/*path` with `If-Match: N` → 200 or 412

All four paths go through the same server-side `Dust.Sync.Writer.write` inside a single `sqlite_transaction` — atomic, no TOCTOU race.

## Process reminder

Subagents implement + test + report. The main session commits. Capver is a protocol change — double-verify the bump lands in BOTH the protocol module AND all three clients that send it.
