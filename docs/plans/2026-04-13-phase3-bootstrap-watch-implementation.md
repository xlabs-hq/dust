# Phase 3 — Bootstrap Watch Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Every task uses TDD: failing test first, then implementation, then hand back to the main session to commit.

**Goal:** Add `include_current: true` to `Dust.on/4` so clients can atomically register a subscription AND receive all currently-matching entries before any live events, closing the race window in the existing "enum-then-on" recovery pattern.

**Architecture:** Extend the existing `SyncEngine.handle_call({:on, ...})` handler to (a) register the subscription first, (b) snapshot current matching entries from the cache via `browse/3`, (c) dispatch bootstrap events to the new subscription's worker synchronously *inside the handle_call*. Because `SyncEngine` is a single-threaded GenServer, no live events can fire while `handle_call` is running — this gives us free ordering: bootstrap items always arrive at the worker before any live events that follow.

**Tech stack:** Same as Phases 1-2. This phase is Elixir/TS-only by design — per the project-level memory (`project_reads_expressible_as_sql.md` and the design doc), Ruby/Python HTTP SDKs use the documented `enum` + webhook catch-up pattern instead of an in-process callback registry.

**Design reference:** `docs/plans/2026-04-13-kv-native-features-design.md` — "Bootstrap Watch" section.

---

## What the recon found (pinned facts)

These facts are load-bearing for the design. Verify them before implementing if you're not sure.

1. **Subscription handle.** `Dust.on/4` returns a `reference()` from `make_ref()` at `sdk/elixir/lib/dust/callback_registry.ex:23`. One `Dust.CallbackWorker` GenServer is spawned per subscription.
2. **Registry storage.** `CallbackRegistry` uses an ETS bag table. Each row is `{store, compiled, pattern, worker_pid, ref, max_queue_size, on_resync}` at `callback_registry.ex:36`.
3. **Live dispatch flow.** `SyncEngine.handle_cast({:server_event, event}, state)` at `sync_engine.ex:544-598` calls `CallbackRegistry.match/3` then dispatches to each matching worker via `CallbackWorker.dispatch/2`, which itself is a `GenServer.cast({:event, event}, ...)`.
4. **Ordering is FIFO per worker.** The SyncEngine is single-threaded, and each worker's mailbox is FIFO, so events fire in the order they were dispatched.
5. **Backpressure.** Before every dispatch, the dispatcher checks `CallbackWorker.queue_len/1`. If `>= max_queue_size` (default 1000 per `callback_registry.ex:2`), the subscription is unregistered and `on_resync` fires with `%{error: :resync_required, ref: ref}` at `sync_engine.ex:610-612`.
6. **Current `on/4` opts parsed.** Only `max_queue_size` (default 1000) and `on_resync` callback. Unknown keys (including `include_current`) are silently ignored today.
7. **No existing snapshot primitive.** The cache has `read_all/3` and `browse/3`, but nothing atomically captures "matching entries + a high-water-mark seq". For Phase 3 we don't need a high-water mark — we rely on the single-threaded GenServer guarantee instead.
8. **Test pattern for callbacks.** Tests use `self()` as the callback target with `send(test_pid, {:event, event})`, then `assert_receive {:event, ...}`. See `sync_engine_test.exs` for examples.

## Semantics pinned down

### `Dust.on/4` with `include_current: true`

```elixir
ref =
  Dust.on(store, pattern, callback,
    include_current: true,
    limit: 50,
    order: :asc
  )
```

- When `include_current: true`, the registration call first **reads all currently-matching entries** from the cache (via `cache.browse/3`, honoring `:limit` and `:order`), then **dispatches each entry to the subscription's worker as a synthetic "present" event** before the call returns.
- The synthetic event shape is: `%{type: :present, path: path, value: value, entry_type: type, seq: seq}`. It's deliberately different from live events (which are written by the server sync protocol and have their own shape) so callback code can distinguish "this is bootstrap" from "this is live" if it cares.
- After the call returns, subsequent live events arrive via the normal `handle_cast({:server_event, ...})` path and are dispatched to the same worker. Because the GenServer is single-threaded, bootstrap items are guaranteed to be enqueued into the worker's mailbox before any live event.
- `include_current: true` on an empty pattern (no matches) returns the ref without emitting anything.
- `include_current: true` without `:limit` uses a default of **50** (conservative, to prevent accidental pathological bootstraps).
- `include_current: true` with `:limit` above 1000 is clamped to 1000.
- `include_current: true` plus `select:` is **not supported** — bootstrap always emits full entries. Reject `select:` at the API layer.

### `Dust.watch/4` alias

```elixir
defdelegate watch(store, pattern, callback, opts \\ []), to: Dust.SyncEngine, as: :on
```

A one-line readability alias. No new semantics.

### Backpressure during bootstrap

- The existing backpressure path runs per-dispatch: if the worker's mailbox exceeds `max_queue_size`, the subscription is unregistered and `on_resync` fires.
- During bootstrap, we call the same dispatch path for each bootstrap entry. If bootstrap would exceed the queue (e.g., 2000-item bootstrap with 1000 max_queue_size), the subscription drops **during** bootstrap, and the caller sees `on_resync` fire.
- This is correct behavior — the subscriber can't keep up, so we fail fast.
- Callers who can't risk this should set `:limit` small enough (< `max_queue_size`).

### What bootstrap does NOT do

- **Does not** return a durable replay from a seq watermark. If live events arrive before registration (client hasn't called `on/4` yet), they are lost — same as today.
- **Does not** deduplicate against live events that happen to match the same path. If a path is written between the snapshot and the "no live events can fire" point, it would appear twice — but this **can't happen** because the single-threaded GenServer blocks all casts during the handle_call.
- **Does not** work for Ruby/Python SDKs (they have no in-process callbacks; they use `enum` + webhook catch-up).

---

## Scope

**In scope:**

1. `SyncEngine.on/4` honors `include_current: true`
2. Bootstrap snapshot via `cache.browse/3`
3. `:limit` and `:order` options during bootstrap
4. Synthetic "present" event dispatch inside `handle_call` for race-free ordering
5. `Dust.watch/4` readability alias
6. Tests for: basic bootstrap, limit, order, no-match, bootstrap + live ordering, backpressure during bootstrap

**Out of scope:**

- Any protocol change (bootstrap is local cache only)
- Any HTTP endpoint (this phase is Elixir/TS only)
- `select:` options during bootstrap (rejected at the API layer)
- TypeScript SDK parity (Phase 4)
- Durable seq-based replay (explicitly deferred in the plan)

---

## Task list

### Task 1: Basic `include_current` emission

**Files:**
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs`

**Step 1: Failing test**

```elixir
describe "on/4 with include_current: true" do
  test "emits current matching entries as :present events before the call returns" do
    store = "test/store"
    Dust.SyncEngine.seed_entry(store, "users.alice.name", "Alice", "string")
    Dust.SyncEngine.seed_entry(store, "users.bob.name", "Bob", "string")

    test_pid = self()
    callback = fn event -> send(test_pid, {:event, event}) end

    _ref = Dust.SyncEngine.on(store, "users.**", callback, include_current: true)

    assert_receive {:event, %{type: :present, path: "users.alice.name", value: "Alice"}}, 500
    assert_receive {:event, %{type: :present, path: "users.bob.name", value: "Bob"}}, 500
  end

  test "include_current: true with no matching entries emits nothing and returns a ref" do
    store = "test/store"
    test_pid = self()
    callback = fn event -> send(test_pid, {:event, event}) end

    ref = Dust.SyncEngine.on(store, "no_match.**", callback, include_current: true)

    assert is_reference(ref)
    refute_receive {:event, _}, 100
  end

  test "include_current: false (default) does not emit current entries" do
    store = "test/store"
    Dust.SyncEngine.seed_entry(store, "users.alice", 1, "integer")

    test_pid = self()
    callback = fn event -> send(test_pid, {:event, event}) end

    _ref = Dust.SyncEngine.on(store, "users.**", callback)

    refute_receive {:event, _}, 100
  end
end
```

**Step 2: Run — FAIL.** (Messages never arrive because `include_current` is currently a no-op.)

**Step 3: Implement**

In `sync_engine.ex`, modify `handle_call({:on, pattern, callback, opts}, _from, state)`. **First** register the subscription via the existing `CallbackRegistry.register/6` call so the worker exists. **Then** check for `include_current: true` in opts; if set, call a new private helper `emit_bootstrap_events/5` that:

1. Pulls matching entries from the cache via `state.cache.browse(state.cache_target, state.store, browse_opts)`.
2. For each entry in the returned page, builds a synthetic `%{type: :present, path: path, value: value, entry_type: type, seq: seq}` map.
3. Calls `Dust.CallbackWorker.dispatch(worker_pid, synthetic_event)` for each — this is the same dispatch path live events use, with the same backpressure check.

Handler shape:

```elixir
@impl true
def handle_call({:on, pattern, callback, opts}, _from, state) do
  {ref, worker_pid} =
    Dust.CallbackRegistry.register(
      state.callbacks,
      state.store,
      pattern,
      callback,
      Keyword.get(opts, :max_queue_size, 1000),
      Keyword.get(opts, :on_resync, fn _ -> :ok end)
    )

  # Bootstrap current matching entries if requested.
  # Runs INSIDE handle_call so no live events can fire between snapshot and return.
  if Keyword.get(opts, :include_current, false) do
    emit_bootstrap_events(state, pattern, worker_pid, ref, opts)
  end

  {:reply, ref, state}
end

defp emit_bootstrap_events(state, pattern, worker_pid, _ref, opts) do
  limit = opts |> Keyword.get(:limit, 50) |> min(1000)
  order = Keyword.get(opts, :order, :asc)

  browse_opts = [
    pattern: pattern,
    limit: limit,
    order: order,
    select: :entries
  ]

  {items, _next_cursor} = state.cache.browse(state.cache_target, state.store, browse_opts)

  Enum.each(items, fn {path, value, type, seq} ->
    event = %{
      type: :present,
      path: path,
      value: value,
      entry_type: type,
      seq: seq
    }

    # Use the same dispatch path live events use — this respects backpressure
    # (dispatcher checks queue_len before enqueueing; if over, drops subscription
    # and fires on_resync).
    dispatch_single_callback(state, worker_pid, event)
  end)
end

defp dispatch_single_callback(state, worker_pid, event) do
  if Dust.CallbackWorker.queue_len(worker_pid) >= max_queue_for(state, worker_pid) do
    # Backpressure — same path as the live dispatcher.
    # TODO confirm the unregister+on_resync flow in callback_registry/sync_engine
    # and mirror it here.
    :drop
  else
    Dust.CallbackWorker.dispatch(worker_pid, event)
  end
end
```

**CRITICAL:** Read the existing `dispatch_callbacks/3` (or similarly-named) in `sync_engine.ex` around line 600. That is the current live-dispatch path and contains the authoritative backpressure logic. Your `dispatch_single_callback/3` helper should reuse it exactly — either call it directly if its shape allows, or copy it verbatim. Do NOT reinvent the backpressure check with slightly different semantics.

**IMPORTANT:** The existing `CallbackRegistry.register/6` may have a different arity or argument list than shown above. Read the actual source (`callback_registry.ex:22-38` per the recon) and match it. The handler sketch above is a starting point, not a drop-in.

**Step 4: Run — PASS.**

**Step 5: Report back for main-session commit.**

Commit message: `feat(sdk): SyncEngine.on/4 supports include_current: true`

---

### Task 2: `limit:` and `order:` during bootstrap

**Files:**
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs`

(Implementation is already covered by Task 1's `emit_bootstrap_events` reading `:limit` and `:order` from opts. This task is just adding tests.)

**Step 1: Failing tests** (but they may actually pass as green if Task 1 wired `limit`/`order` correctly — check and adjust):

```elixir
test "include_current honors :limit" do
  store = "test/store"
  for i <- 1..10, do: Dust.SyncEngine.seed_entry(store, "k.#{i}", i, "integer")

  test_pid = self()
  callback = fn event -> send(test_pid, {:event, event}) end

  _ref = Dust.SyncEngine.on(store, "k.**", callback, include_current: true, limit: 3)

  # Collect all arrived events (up to 200ms window)
  events = drain_events(200)
  assert length(events) == 3
end

test "include_current honors :order :desc" do
  store = "test/store"
  for k <- ~w(a b c), do: Dust.SyncEngine.seed_entry(store, k, k, "string")

  test_pid = self()
  callback = fn event -> send(test_pid, {:event, event}) end

  _ref = Dust.SyncEngine.on(store, "**", callback, include_current: true, order: :desc, limit: 10)

  events = drain_events(200)
  paths = Enum.map(events, & &1.path)
  assert paths == ["c", "b", "a"]
end

test "include_current clamps :limit above 1000" do
  # Hard to test the clamp without 1001 entries. Seed 5, request limit: 9999,
  # verify we still get all 5 (and the internal clamp is a guard, not a bug).
  store = "test/store"
  for k <- ~w(a b c d e), do: Dust.SyncEngine.seed_entry(store, k, k, "string")

  test_pid = self()
  callback = fn event -> send(test_pid, {:event, event}) end

  _ref = Dust.SyncEngine.on(store, "**", callback, include_current: true, limit: 9999)

  events = drain_events(200)
  assert length(events) == 5
end

# Test helper
defp drain_events(timeout_ms) do
  receive do
    {:event, event} -> [event | drain_events(timeout_ms)]
  after
    timeout_ms -> []
  end
end
```

**Step 2: Run. If already green (because Task 1 implemented these correctly), mark done. If red, fix whatever's missing in `emit_bootstrap_events`.**

**Step 3: Commit**

Message: `test(sdk): bootstrap watch honors :limit and :order`

---

### Task 3: Race-free ordering — bootstrap before live events

**Files:**
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs`

**Step 1: Failing test**

```elixir
test "bootstrap events arrive before any live events dispatched after registration" do
  store = "test/store"
  Dust.SyncEngine.seed_entry(store, "items.1", 1, "integer")
  Dust.SyncEngine.seed_entry(store, "items.2", 2, "integer")

  test_pid = self()
  callback = fn event -> send(test_pid, {:event, event}) end

  _ref = Dust.SyncEngine.on(store, "items.**", callback, include_current: true)

  # After registration, dispatch a fake server event via the same path live writes use.
  # This simulates a live write landing right after the subscription was registered.
  Dust.SyncEngine.handle_server_event(store, %{
    path: "items.3",
    value: 3,
    type: "integer",
    seq: 100
  })

  events = drain_events(200)
  paths = Enum.map(events, & &1.path)

  # The two bootstrap items MUST appear before the live item,
  # regardless of absolute timing.
  assert Enum.find_index(paths, &(&1 == "items.1")) < Enum.find_index(paths, &(&1 == "items.3"))
  assert Enum.find_index(paths, &(&1 == "items.2")) < Enum.find_index(paths, &(&1 == "items.3"))
end
```

**Step 2: Run.**

This test **should already pass** if Task 1 was implemented correctly — the whole point of dispatching bootstrap events inside `handle_call` is that subsequent casts can't interleave. If it fails, the bootstrap is being done OUTSIDE `handle_call` (e.g., spawned as a task), which breaks the ordering guarantee. Fix by moving the dispatch back inside `handle_call`.

**Step 3: Commit**

Message: `test(sdk): bootstrap events precede live events in worker mailbox`

---

### Task 4: Backpressure during bootstrap

**Files:**
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs` (or `backpressure_test.exs` if that's where similar tests live)

**Step 1: Failing test**

```elixir
test "bootstrap that exceeds max_queue_size unregisters and fires on_resync" do
  store = "test/store"
  for i <- 1..50, do: Dust.SyncEngine.seed_entry(store, "k.#{i}", i, "integer")

  test_pid = self()
  # Callback blocks forever so the worker can't drain its mailbox
  callback = fn _event ->
    receive do
      :continue -> :ok
    end
  end

  on_resync = fn reason -> send(test_pid, {:resync, reason}) end

  _ref = Dust.SyncEngine.on(store, "k.**", callback,
    include_current: true,
    limit: 50,
    max_queue_size: 5,
    on_resync: on_resync
  )

  # Expect the subscription to drop and resync to fire during bootstrap
  assert_receive {:resync, %{error: :resync_required}}, 500
end
```

**Step 2: Run.**

This test should pass IF `dispatch_single_callback/3` correctly reuses the existing backpressure check (queue_len + unregister + on_resync). If it instead bypasses backpressure during bootstrap, this test fails and you need to fix the dispatch helper.

**Step 3: Commit**

Message: `test(sdk): bootstrap respects backpressure and fires on_resync when queue overflows`

---

### Task 5: `Dust.watch/4` alias

**Files:**
- Modify: `sdk/elixir/lib/dust.ex`
- Modify: `sdk/elixir/test/dust_test.exs`

**Step 1: Failing test**

```elixir
test "Dust.watch/4 is an alias for Dust.on/4" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")

  test_pid = self()
  callback = fn event -> send(test_pid, {:event, event}) end

  ref = Dust.watch(store, "**", callback, include_current: true)

  assert is_reference(ref)
  assert_receive {:event, %{path: "a"}}, 200
end
```

**Step 2: Run — FAIL** (Dust.watch/4 undefined).

**Step 3: Implement**

In `sdk/elixir/lib/dust.ex`:

```elixir
defdelegate watch(store, pattern, callback, opts \\ []), to: Dust.SyncEngine, as: :on
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk): Dust.watch/4 as readability alias for on/4`

---

### Task 6: End-to-end verification

**Files:** none modified.

**Step 1:** SDK full suite:
```bash
cd sdk/elixir && mix test
```
Expected: all green. ~195 tests (187 at end of Phase 2 + ~8 new from Phase 3).

**Step 2: No commit needed.**

---

## Verification checklist

- [ ] `Dust.on/4` with `include_current: true` emits all current matching entries as synthetic `%{type: :present, ...}` events before returning.
- [ ] `include_current: false` (default) does not emit current entries.
- [ ] `include_current` honors `:limit` (default 50, clamped to 1000).
- [ ] `include_current` honors `:order` (asc / desc).
- [ ] No match → no events emitted, ref still returned.
- [ ] Bootstrap events always arrive at the worker before any live events dispatched after registration (race-free).
- [ ] Backpressure applies during bootstrap — exceeding max_queue_size unregisters and fires on_resync.
- [ ] `Dust.watch/4` alias exists.
- [ ] No `try`/`rescue` anywhere in new code.
- [ ] All Phase 1 and 2 tests still pass (no regressions).

## Cross-SDK parity check

This phase is deliberately Elixir/TS only. Ruby/Python don't have in-process callbacks.

For Ruby/Python, the equivalent workflow is documented as:

1. On worker boot, call `GET /api/stores/:org/:store/entries?pattern=X&limit=N` to hydrate the local SQLite cache.
2. Configure a webhook subscription for the store (already existing HTTP endpoint).
3. Webhook events drive live updates, with `CatchUpWorker` closing any gap between the enum snapshot and the first live webhook event via `last_delivered_seq`.

No HTTP endpoint is added in this phase. The existing `GET /entries` (Phase 1) and webhook subscriptions (pre-Phase-1) already provide everything Ruby/Python need.

## Process reminder

Subagents implement + test + report. The main session commits. The "Commit" step in each task above is done by the main session, not the subagent.
