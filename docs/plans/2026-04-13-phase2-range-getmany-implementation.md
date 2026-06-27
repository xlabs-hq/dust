# Phase 2 — Range & Batch Reads Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Every task uses TDD: write the failing test first, verify it fails, implement minimally, verify it passes, hand back to the main session to commit.

**Goal:** Ship `Dust.range/4` (lexicographic range query) and `Dust.get_many/2` (batched read) in the Elixir SDK, plus matching HTTP endpoints on the Phoenix server, building on Phase 1's `%Dust.Page{}`, cursor pagination, and `Dust.Cache.read_entry/3` infrastructure.

**Architecture:** Extend `Dust.Cache.browse/3` to accept optional `:from`/`:to` bounds (mutually exclusive with `:pattern`) so range and enum share the same chunked keyset paginator. Add a new required `Dust.Cache.read_many/3` callback — Memory loops, Ecto does `WHERE path IN (...)`. SyncEngine and server both get thin wrappers that compose existing primitives. HTTP range is overloaded onto `GET /entries` (query params `from`/`to`); HTTP batch is a new `POST /entries/batch` route ordered before the `*path` wildcard.

**Tech stack:** Same as Phase 1 — Elixir 1.19, Phoenix 1.8, Ecto 3, SQLite per store, existing `ApiTokenAuth` plug, `Dust.Glob` for pattern matching (Phase 1 result).

**Design reference:** `docs/plans/2026-04-13-kv-native-features-design.md` — "Phase 2" section, plus the cross-SDK guidelines (reads-expressible-as-SQL, cache schema parity).

---

## What Phase 1 gave us that this plan reuses

- `%Dust.Page{}` struct with Enumerable impl — reused verbatim for `range/4` results.
- `%Dust.Entry{}` struct — reused for HTTP batch response items.
- `Dust.Cache.browse/3` with `:limit`, `:cursor`, `:order`, `:select` — extended, not replaced.
- `Dust.Cache.read_entry/3` — used as the fallback when `read_many/3` isn't implemented.
- `Dust.Sync.enum_entries/3` server-side chunked-walk primitive + the `path > ?` / `path < ?` cursor logic — reused for range.
- `DustWeb.Api.EntriesApiController` — gets new actions (`batch/2`, and `index/2` learns to route to range).
- The C1/I1 fix (chunked fetch + LIKE escape) — range benefits automatically since range doesn't need LIKE at all (bounds cover the prefix).
- `Dust.Glob.match?/2` — not used by range (range has no glob), referenced here only so nobody gets confused.

## Semantics pinned down

### `Dust.range/4`

```elixir
Dust.range(store, from, to, opts \\ [])
# => %Dust.Page{items: [...], next_cursor: nil | String.t()}
```

- Both `from` and `to` are **required binaries** (open-ended ranges are out of scope for Phase 2).
- `from` is **inclusive**, `to` is **exclusive**. Matches SQL `WHERE path >= ? AND path < ?`.
- Options: `:limit` (default 50, max 1000), `:after` (opaque cursor), `:order` (`:asc` default | `:desc`), `:select` (`:entries` default | `:keys`).
- `:prefixes` is **not supported** by `range/4`. It's tied to glob pattern semantics; calling `range` with `select: :prefixes` returns `{:error, :unsupported_select}`.
- If `from >= to`, return `%Dust.Page{items: [], next_cursor: nil}` (empty, no error — simpler for callers).
- Items are `%Dust.Entry{}` (for `:entries`) or path strings (for `:keys`).

### `Dust.get_many/2`

```elixir
Dust.get_many(store, paths)
# => %{path => value}
```

- `paths` is a list of path strings. Order of input is not preserved in the output map.
- Missing paths are omitted from the result (no `:missing` sentinel). This matches Phase 1 design.
- Values are materialized (decoded, `FileRef`-wrapped for file entries), matching `Dust.get/2` behavior.
- Empty input list returns `%{}`.

### HTTP routes

- **Range is overloaded onto `GET /api/stores/:org/:store/entries`.**
  - If query params include `from` AND `to`, route to range.
  - If query params include `pattern` (or none of from/to/pattern), route to enum (existing behavior).
  - If both `pattern` and `from`/`to` are set → 400 `{"error": "conflicting_params", "detail": "use either pattern or from/to, not both"}`.
  - Range response shape matches enum: `{"items": [...], "next_cursor": ...}`.

- **Batch is a new route: `POST /api/stores/:org/:store/entries/batch`**
  - Body: `{"paths": ["users.alice.name", "users.bob.name"]}`.
  - Response (rich envelope, since HTTP clients need metadata for cache hydration):
    ```json
    {
      "entries": {
        "users.alice.name": {"value": "Alice", "type": "string", "revision": 7}
      },
      "missing": ["users.bob.name"]
    }
    ```
  - Missing paths are explicit (unlike the SDK shape) because HTTP clients typically need to know what they asked for that wasn't there. The SDK does not expose `missing` because SDK callers can compare `Map.keys` themselves.
  - Route ordering: MUST be defined before `get "/stores/:org/:store/entries/*path"` or the wildcard will eat `/batch`. Phoenix routes match in definition order.
  - Accepts up to 1000 paths per request; more returns 400.

---

## Scope

**In scope:**

1. `Dust.Cache.browse/3` extended with `:from`/`:to` options
2. `Dust.Cache.read_many/3` new required callback
3. Memory + Ecto adapter implementations of both
4. `Dust.SyncEngine.range/4` handler + `get_many/2` handler
5. `Dust.range/4` + `Dust.get_many/2` public delegates
6. `Dust.Sync.range_entries/4` server-side function
7. `Dust.Sync.get_many_entries/2` server-side function
8. `DustWeb.Api.EntriesApiController.index/2` learns to dispatch enum vs range
9. `DustWeb.Api.EntriesApiController.batch/2` new action + route
10. Full TDD + tests at every layer

**Out of scope:**

- Open-ended ranges (only `from` or only `to`). If a user passes one without the other, reject at the API layer for now.
- `select: :prefixes` for range (nonsense).
- Typescript/CLI parity (Phase 4).
- CAS (Phase 5).
- The `Dust.entry/2` subtree-assembly follow-up — still deferred.
- Breaking or changing any Phase 1 shape.

---

## Task list

### Task 1: Memory cache — `browse` with `:from`/`:to` bounds

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/memory.ex`
- Modify: `sdk/elixir/test/dust/cache/memory_test.exs`

**Step 1: Write the failing tests**

```elixir
describe "browse with :from/:to range" do
  test "returns entries within [from, to) lexicographically", %{cache: pid} do
    for k <- ~w(a b c d e), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)

    {page, _} = Dust.Cache.Memory.browse(pid, "s", from: "b", to: "d", limit: 10)
    paths = Enum.map(page, fn {p, _, _, _} -> p end)
    assert paths == ~w(b c)
  end

  test "from is inclusive, to is exclusive", %{cache: pid} do
    for k <- ~w(a b c), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)
    {page, _} = Dust.Cache.Memory.browse(pid, "s", from: "a", to: "c", limit: 10)
    assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(a b)
  end

  test "from >= to returns an empty page", %{cache: pid} do
    :ok = Dust.Cache.Memory.write(pid, "s", "x", "x", "string", 1)
    {page, _} = Dust.Cache.Memory.browse(pid, "s", from: "z", to: "a", limit: 10)
    assert page == []
  end

  test "range respects order: :desc", %{cache: pid} do
    for k <- ~w(a b c d), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)
    {page, _} = Dust.Cache.Memory.browse(pid, "s", from: "a", to: "d", limit: 10, order: :desc)
    assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(c b a)
  end

  test "range + limit produces a next_cursor", %{cache: pid} do
    for k <- ~w(a b c d e), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)
    {page, cursor} = Dust.Cache.Memory.browse(pid, "s", from: "a", to: "z", limit: 2)
    assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(a b)
    assert cursor == "b"
  end

  test "range + cursor resumes correctly", %{cache: pid} do
    for k <- ~w(a b c d e), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)
    {page, _} = Dust.Cache.Memory.browse(pid, "s", from: "a", to: "z", limit: 2, cursor: "b")
    assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(c d)
  end
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

In `handle_call({:browse, store, opts}, ...)`, add the range filter. Range and pattern should be mutually exclusive — if both are set, range wins (or the outer layer already rejected). For the adapter, if `:from` is in opts, skip the glob filter entirely and filter by `path >= from and path < to`:

```elixir
from = Keyword.get(opts, :from)
to = Keyword.get(opts, :to)

entries =
  state.entries
  |> Enum.filter(fn {{s, path}, _} ->
    s == store and path_in_filter?(path, pattern, compiled, from, to)
  end)
  |> Enum.map(fn {{_s, path}, {value, type, seq}} -> {path, value, type, seq} end)
  |> Enum.sort_by(fn {p, _, _, _} -> p end, sort_direction(order))
```

And add:

```elixir
defp path_in_filter?(_path, _pattern, _compiled, from, to) when is_binary(from) and is_binary(to) do
  path_between?(from, to)
end

defp path_in_filter?(path, _pattern, compiled, nil, nil) do
  Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
end

defp path_between?(from, to) do
  fn path -> path >= from and path < to end
end
```

Wait — that's a function returning a function, which is awkward inside the filter. Simpler: inline it. Refactor:

```elixir
entries =
  state.entries
  |> Enum.filter(fn {{s, path}, _} ->
    s == store and matches_filter?(path, pattern, compiled, from, to)
  end)
  ...

defp matches_filter?(path, _pattern, _compiled, from, to) when is_binary(from) and is_binary(to) do
  path >= from and path < to
end

defp matches_filter?(path, _pattern, compiled, _from, _to) do
  Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
end
```

Note: if `from >= to`, the filter returns false for all paths, which gives an empty page — matches the spec.

Cursor handling needs to still work: `apply_cursor/3` already handles the asc/desc split based on `order`. No change needed there.

**Step 4: Run — PASS.**

**Step 5: Report back and hand off to main session for commit.**

Commit message for main session: `feat(sdk): Memory browse supports :from/:to range filter`

---

### Task 2: Ecto cache — `browse` with `:from`/`:to` bounds

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Modify: `sdk/elixir/test/dust/cache/ecto_test.exs`

**Step 1: Failing tests**

Mirror Task 1's six tests against the Ecto adapter. Use the existing `Dust.TestRepo` setup pattern.

**Step 2: Run — FAIL.**

**Step 3: Implement**

In `Dust.Cache.Ecto.browse/3`, read `:from` and `:to`. When both are set, replace the glob LIKE filter entirely with a pure range `where` clause:

```elixir
from_key = Keyword.get(opts, :from)
to_key = Keyword.get(opts, :to)

# ... existing initial query ...

query =
  if is_binary(from_key) and is_binary(to_key) do
    from(c in query, where: c.path >= ^from_key and c.path < ^to_key)
  else
    # existing LIKE-prefix branch for pattern queries
  end
```

No post-filter glob is needed when range is active. The chunked keyset walk from the Phase 1 C1 fix is still required in the pattern case but **is NOT needed for range** (because SQL bounds are exact — every raw row inside `[from, to)` is already a valid match). You can bypass `collect_matches_chunked/7` entirely when `from_key`/`to_key` are set, fetching `limit+1` rows in one shot. Much simpler.

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk): Ecto browse supports :from/:to range filter`

---

### Task 3: `Dust.Cache.read_many/3` callback + Memory impl

**Files:**
- Modify: `sdk/elixir/lib/dust/cache.ex`
- Modify: `sdk/elixir/lib/dust/cache/memory.ex`
- Modify: `sdk/elixir/test/dust/cache/memory_test.exs`

**Step 1: Add the callback declaration** (no test, purely a behaviour change):

```elixir
@callback read_many(target :: term(), store :: String.t(), paths :: [String.t()]) ::
            %{String.t() => {value :: term(), type :: String.t(), seq :: integer()}}
```

Do NOT add `read_many: 3` to `@optional_callbacks`. Every adapter must implement it.

**Step 2: Failing tests for Memory impl**

```elixir
describe "read_many/3" do
  test "returns a map of present entries", %{cache: pid} do
    :ok = Dust.Cache.Memory.write(pid, "s", "a", 1, "integer", 1)
    :ok = Dust.Cache.Memory.write(pid, "s", "b", 2, "integer", 2)
    result = Dust.Cache.Memory.read_many(pid, "s", ["a", "b"])
    assert result == %{"a" => {1, "integer", 1}, "b" => {2, "integer", 2}}
  end

  test "omits missing paths", %{cache: pid} do
    :ok = Dust.Cache.Memory.write(pid, "s", "a", 1, "integer", 1)
    result = Dust.Cache.Memory.read_many(pid, "s", ["a", "missing"])
    assert Map.keys(result) == ["a"]
  end

  test "empty list returns empty map", %{cache: pid} do
    assert Dust.Cache.Memory.read_many(pid, "s", []) == %{}
  end

  test "duplicate paths collapse in the result", %{cache: pid} do
    :ok = Dust.Cache.Memory.write(pid, "s", "a", 1, "integer", 1)
    result = Dust.Cache.Memory.read_many(pid, "s", ["a", "a", "a"])
    assert result == %{"a" => {1, "integer", 1}}
  end
end
```

**Step 3: Run — FAIL.**

**Step 4: Implement**

```elixir
@impl Dust.Cache
def read_many(pid, store, paths) do
  GenServer.call(pid, {:read_many, store, paths})
end

# in handle_call region:
@impl true
def handle_call({:read_many, store, paths}, _from, state) do
  result =
    paths
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn path, acc ->
      case Map.get(state.entries, {store, path}) do
        nil -> acc
        tuple -> Map.put(acc, path, tuple)
      end
    end)

  {:reply, result, state}
end
```

**Step 5: Run — PASS.**

**Step 6: Commit**

Message: `feat(sdk): add read_many/3 callback and Memory implementation`

---

### Task 4: Ecto `read_many/3` impl

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Modify: `sdk/elixir/test/dust/cache/ecto_test.exs`

**Step 1: Failing tests** — mirror Task 3 against Ecto.

**Step 2: Implement**

```elixir
@impl Dust.Cache
def read_many(repo, store, paths) do
  unique_paths = Enum.uniq(paths)

  if unique_paths == [] do
    %{}
  else
    query =
      from(c in CacheEntry,
        where: c.store == ^store and c.path in ^unique_paths,
        select: {c.path, c.value, c.type, c.seq}
      )

    repo.all(query)
    |> Enum.reduce(%{}, fn {path, json, type, seq}, acc ->
      Map.put(acc, path, {Jason.decode!(json), type, seq})
    end)
  end
end
```

**Step 3: Run — PASS.**

**Step 4: Commit**

Message: `feat(sdk): Ecto read_many/3 via SELECT WHERE path IN`

---

### Task 5: `SyncEngine.range/4` handler + `Dust.range/4` delegate

**Files:**
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Modify: `sdk/elixir/lib/dust.ex`
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs`
- Modify: `sdk/elixir/test/dust_test.exs`

**Step 1: Failing tests (both files)**

In `sync_engine_test.exs`:

```elixir
test "range/4 returns a Page with entries in [from, to)" do
  store = "test/store"
  for k <- ~w(a b c d e), do: Dust.SyncEngine.seed_entry(store, k, k, "string")

  assert %Dust.Page{items: items, next_cursor: nil} =
           Dust.SyncEngine.range(store, "a", "d", limit: 10)

  paths = Enum.map(items, & &1.path)
  assert paths == ~w(a b c)
end

test "range/4 with select: :keys returns path strings" do
  store = "test/store"
  for k <- ~w(a b c), do: Dust.SyncEngine.seed_entry(store, k, k, "string")
  assert %Dust.Page{items: ~w(a b c)} =
           Dust.SyncEngine.range(store, "a", "z", select: :keys)
end

test "range/4 rejects select: :prefixes" do
  store = "test/store"
  assert Dust.SyncEngine.range(store, "a", "z", select: :prefixes) == {:error, :unsupported_select}
end

test "range/4 with from >= to returns an empty page" do
  store = "test/store"
  Dust.SyncEngine.seed_entry(store, "x", "x", "string")
  assert %Dust.Page{items: [], next_cursor: nil} =
           Dust.SyncEngine.range(store, "z", "a")
end
```

In `dust_test.exs`:

```elixir
test "Dust.range/4 delegates to SyncEngine" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  assert %Dust.Page{items: [%Dust.Entry{path: "a"}]} = Dust.range(store, "a", "z", limit: 10)
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

In `sync_engine.ex`, add the public fn:

```elixir
def range(store, from, to, opts \\ []) when is_binary(from) and is_binary(to) do
  GenServer.call(via(store), {:range, from, to, opts})
end
```

Handler:

```elixir
@impl true
def handle_call({:range, from, to, opts}, _from, state) do
  case Keyword.get(opts, :select, :entries) do
    :prefixes ->
      {:reply, {:error, :unsupported_select}, state}

    select when select in [:entries, :keys] ->
      limit = opts |> Keyword.get(:limit, 50) |> min(1000)
      order = Keyword.get(opts, :order, :asc)
      cursor = Keyword.get(opts, :after)

      browse_opts = [
        from: from,
        to: to,
        limit: limit,
        order: order,
        select: select,
        cursor: cursor
      ]

      {items, next_cursor} = state.cache.browse(state.cache_target, state.store, browse_opts)
      page = Dust.Page.new(items: wrap_items(items, select), next_cursor: next_cursor)
      {:reply, page, state}
  end
end
```

(`wrap_items/2` already exists from Phase 1.)

In `dust.ex`:

```elixir
defdelegate range(store, from, to, opts \\ []), to: Dust.SyncEngine
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk): Dust.range/4 returns paged Dust.Page within [from, to)`

---

### Task 6: `SyncEngine.get_many/2` handler + `Dust.get_many/2` delegate

**Files:**
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Modify: `sdk/elixir/lib/dust.ex`
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs`
- Modify: `sdk/elixir/test/dust_test.exs`

**Step 1: Failing tests**

```elixir
test "get_many/2 returns a map of present values" do
  store = "test/store"
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  Dust.SyncEngine.seed_entry(store, "b", 2, "integer")

  assert Dust.SyncEngine.get_many(store, ["a", "b"]) == %{"a" => 1, "b" => 2}
end

test "get_many/2 omits missing paths" do
  store = "test/store"
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  assert Dust.SyncEngine.get_many(store, ["a", "missing"]) == %{"a" => 1}
end

test "get_many/2 with empty list returns empty map" do
  assert Dust.SyncEngine.get_many("test/store", []) == %{}
end

test "get_many/2 unwraps file references" do
  # match what Dust.get/2 does for file entries — see handle_call({:get, ...})
  # Only needed if the existing cache has FileRef entries in tests. If not,
  # skip this test and document that file-ref unwrapping happens in the
  # handler.
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

In `sync_engine.ex`:

```elixir
def get_many(store, paths) when is_list(paths) do
  GenServer.call(via(store), {:get_many, paths})
end
```

Handler:

```elixir
@impl true
def handle_call({:get_many, paths}, _from, state) do
  raw = state.cache.read_many(state.cache_target, state.store, paths)

  result =
    Enum.reduce(raw, %{}, fn {path, {value, _type, _seq}}, acc ->
      Map.put(acc, path, unwrap_value(value))
    end)

  {:reply, result, state}
end

defp unwrap_value(%{"_type" => "file"} = map), do: Dust.FileRef.from_map(map)
defp unwrap_value(other), do: other
```

(The `unwrap_value/1` helper mirrors the existing `handle_call({:get, path}, ...)` file-ref handling at `sync_engine.ex:127-137`. If there's already a private helper for this, reuse it — don't duplicate.)

In `dust.ex`:

```elixir
defdelegate get_many(store, paths), to: Dust.SyncEngine
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk): Dust.get_many/2 returns map of present values`

---

### Task 7: Server `Dust.Sync.range_entries/4`

**Files:**
- Modify: `server/lib/dust/sync.ex`
- Create / Modify: `server/test/dust/sync_range_test.exs` OR add tests inline to the existing sync test file (check which pattern the repo uses)

**Step 1: Read `Dust.Sync.enum_entries/3` carefully first.** The range version reuses most of its structure — chunked fetch, `path > ?` / `path < ?` cursor, projection — but drops the pattern/glob logic and replaces the `LIKE` clause with `path >= ? AND path < ?`. No glob post-filter needed.

**Step 2: Failing tests**

Seed 5 entries (`a, b, c, d, e`), call `range_entries(store_id, "b", "e", limit: 10)`, expect `b, c, d`. Plus: asc/desc order, cursor continuation, `from >= to` returns empty, `:keys` projection, `:prefixes` returns `{:error, :unsupported_select}`.

**Step 3: Implement**

```elixir
@spec range_entries(binary(), String.t(), String.t(), keyword()) ::
        {:ok, %{items: list(), next_cursor: String.t() | nil}}
        | {:error, :unsupported_select}
def range_entries(store_id, from, to, opts \\ []) when is_binary(from) and is_binary(to) do
  case Keyword.get(opts, :select, :entries) do
    :prefixes ->
      {:error, :unsupported_select}

    select when select in [:entries, :keys] ->
      limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()
      order = Keyword.get(opts, :order, :asc)
      cursor = Keyword.get(opts, :after)

      result =
        with_read_conn(store_id, fn conn ->
          rows = fetch_range_rows(conn, from, to, cursor, order, limit + 1)
          {page, next_cursor} = split_page_with_cursor(rows, limit)
          %{items: project_rows(page, select, nil), next_cursor: next_cursor}
        end) || %{items: [], next_cursor: nil}

      {:ok, result}
  end
end

defp fetch_range_rows(conn, from, to, cursor, order, limit) do
  # Build SQL like:
  #   SELECT path, value, type, seq
  #   FROM store_entries
  #   WHERE path >= ? AND path < ?
  #     [AND path > ?]  -- asc cursor
  #     [AND path < ?]  -- desc cursor
  #   ORDER BY path ASC|DESC
  #   LIMIT ?
  #
  # Use the same query helper used by enum_entries (probably query_all/3).
  ...
end
```

Note: range doesn't need the chunked-walk loop from Phase 1 C1 because there's no post-filter — every row in `[from, to)` is a match. A single SQL query with `LIMIT limit+1` is sufficient.

`split_page_with_cursor/2` may already exist from Phase 1 (check — it's the helper that takes `limit+1` rows and returns `{page, next_cursor}`). Reuse if it does; extract a small helper if not.

`project_rows/3` already exists. Pass `nil` for the pattern argument since range doesn't need it (project for `:entries` decodes values via ValueCodec; for `:keys` returns path strings; for `:prefixes` it'd try to compute prefixes — which is why we reject `:prefixes` up-front).

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(server): Dust.Sync.range_entries/4 reads [from, to) with cursor pagination`

---

### Task 8: Server `Dust.Sync.get_many_entries/2`

**Files:**
- Modify: `server/lib/dust/sync.ex`
- Modify: test file (same one as Task 7)

**Step 1: Failing tests**

```elixir
test "get_many_entries returns a map with entries and missing list" do
  store = create_test_store()
  Dust.Sync.write(store.id, %{op: :put, path: "a", value: 1, ...})
  Dust.Sync.write(store.id, %{op: :put, path: "b", value: 2, ...})

  assert %{entries: entries, missing: missing} =
           Dust.Sync.get_many_entries(store.id, ["a", "b", "c"])

  assert entries["a"] == %{value: 1, type: "integer", seq: _}
  assert entries["b"] == %{value: 2, type: "integer", seq: _}
  assert missing == ["c"]
end

test "get_many_entries with empty list returns empty result" do
  store = create_test_store()
  assert %{entries: %{}, missing: []} = Dust.Sync.get_many_entries(store.id, [])
end
```

Note: server returns the rich envelope `%{entries: %{path => %{value, type, seq}}, missing: [path]}`. The `seq` field name stays internal; the HTTP controller renames it to `revision`.

**Step 2: Implement**

```elixir
@spec get_many_entries(binary(), [String.t()]) :: %{entries: map(), missing: [String.t()]}
def get_many_entries(store_id, paths) when is_list(paths) do
  unique_paths = Enum.uniq(paths)

  if unique_paths == [] do
    %{entries: %{}, missing: []}
  else
    with_read_conn(store_id, fn conn ->
      placeholders = Enum.map_join(unique_paths, ", ", fn _ -> "?" end)
      sql = "SELECT path, value, type, seq FROM store_entries WHERE path IN (#{placeholders})"
      rows = query_all(conn, sql, unique_paths)

      entries =
        Enum.reduce(rows, %{}, fn [path, json, type, seq], acc ->
          value = json |> Jason.decode!() |> ValueCodec.unwrap()
          Map.put(acc, path, %{value: value, type: type, seq: seq})
        end)

      found_paths = Map.keys(entries)
      missing = unique_paths -- found_paths

      %{entries: entries, missing: missing}
    end) || %{entries: %{}, missing: unique_paths}
  end
end
```

**Careful:** String interpolation into SQL is usually an injection risk, but here we're only interpolating the count of `?` placeholders, not values. The values still go through parameterized binding via `query_all`. Verify this is how the existing code builds IN queries in `server/lib/dust/sync.ex` — if not, follow whatever pattern is already used.

**Step 3: Run — PASS.**

**Step 4: Commit**

Message: `feat(server): Dust.Sync.get_many_entries/2 batched read`

---

### Task 9: HTTP — `GET /entries` dispatches to range when from/to present

**Files:**
- Modify: `server/lib/dust_web/controllers/api/entries_api_controller.ex`
- Modify: `server/test/dust_web/controllers/api/entries_api_controller_test.exs`

**Step 1: Failing tests**

```elixir
test "GET /entries?from=b&to=e returns range results", %{conn: conn, org: org, store: store} do
  # seed a..f first
  conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?from=b&to=e")
  body = json_response(conn, 200)
  assert Enum.map(body["items"], & &1["path"]) == ~w(b c d)
end

test "GET /entries?from=b&to=e&select=keys returns path strings only", %{conn: conn, org: org, store: store} do
  conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?from=b&to=e&select=keys")
  assert json_response(conn, 200)["items"] == ~w(b c d)
end

test "GET /entries with both pattern and from returns 400", %{conn: conn, org: org, store: store} do
  conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?pattern=users.**&from=a&to=z")
  body = json_response(conn, 400)
  assert body["error"] == "conflicting_params"
end

test "GET /entries with from but no to returns 400", %{conn: conn, org: org, store: store} do
  conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?from=a")
  assert json_response(conn, 400)["error"] == "invalid_params"
end

test "GET /entries range paginates via next_cursor", %{conn: conn, org: org, store: store} do
  # seed many entries, request limit=2, follow next_cursor
  ...
end
```

**Step 2: Implement**

In `index/2`, branch on presence of `from` vs `pattern`:

```elixir
def index(conn, params) do
  with :ok <- validate_mutually_exclusive(params),
       {:ok, store} <- fetch_store(conn, params),
       :ok <- verify_read_permission(conn.assigns.store_token) do
    case dispatch_mode(params) do
      :range -> do_range(conn, store, params)
      :enum -> do_enum(conn, store, params)
    end
  else
    # ... existing error handling ...
  end
end

defp validate_mutually_exclusive(params) do
  cond do
    Map.has_key?(params, "pattern") and Map.has_key?(params, "from") ->
      {:error, {:conflicting_params, "use either pattern or from/to, not both"}}

    Map.has_key?(params, "from") and not Map.has_key?(params, "to") ->
      {:error, {:invalid_params, "from requires to"}}

    Map.has_key?(params, "to") and not Map.has_key?(params, "from") ->
      {:error, {:invalid_params, "to requires from"}}

    true ->
      :ok
  end
end

defp dispatch_mode(params) do
  if Map.has_key?(params, "from"), do: :range, else: :enum
end
```

Extract the existing enum body into `do_enum/3` and add `do_range/3` that parses `from`, `to`, `limit`, `after`, `order`, `select` (reject `:prefixes`) and calls `Dust.Sync.range_entries/4`.

Error path for `conflicting_params`: return 400 with `{"error": "conflicting_params", "detail": ...}`.

**Step 3: Run — PASS.**

**Step 4: Commit**

Message: `feat(server): GET /entries dispatches to range when from/to present`

---

### Task 10: HTTP — `POST /entries/batch`

**Files:**
- Modify: `server/lib/dust_web/controllers/api/entries_api_controller.ex`
- Modify: `server/lib/dust_web/router.ex`
- Modify: `server/test/dust_web/controllers/api/entries_api_controller_test.exs`

**Step 1: Failing tests**

```elixir
test "POST /entries/batch returns entries + missing", %{conn: conn, org: org, store: store} do
  conn = post(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries/batch",
    %{"paths" => ["users.alice.name", "users.bob.name", "users.no_such"]})

  body = json_response(conn, 200)
  assert body["entries"]["users.alice.name"]["value"] == "Alice"
  assert body["entries"]["users.alice.name"]["revision"] |> is_integer()
  assert body["missing"] == ["users.no_such"]
end

test "POST /entries/batch with empty paths returns empty result", %{conn: conn, org: org, store: store} do
  conn = post(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries/batch", %{"paths" => []})
  assert json_response(conn, 200) == %{"entries" => %{}, "missing" => []}
end

test "POST /entries/batch without paths returns 400", %{conn: conn, org: org, store: store} do
  conn = post(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries/batch", %{})
  assert json_response(conn, 400)["error"] == "invalid_params"
end

test "POST /entries/batch with > 1000 paths returns 400", %{conn: conn, org: org, store: store} do
  too_many = for i <- 1..1001, do: "p.#{i}"
  conn = post(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries/batch", %{"paths" => too_many})
  assert json_response(conn, 400)["error"] == "invalid_params"
end

test "POST /entries/batch without Bearer token returns 401", %{org: org, store: store} do
  conn = post(build_conn(), ~p"/api/stores/#{org.slug}/#{store.name}/entries/batch",
    %{"paths" => ["a"]})
  assert response(conn, 401)
end
```

**Step 2: Add the route** in `server/lib/dust_web/router.ex`. **CRITICAL: route ordering.** The batch route MUST come BEFORE `get "/stores/:org/:store/entries/*path"`. Phoenix router matches in definition order, and `/entries/batch` would otherwise be captured by the wildcard.

```elixir
get "/stores/:org/:store/entries", EntriesApiController, :index
post "/stores/:org/:store/entries/batch", EntriesApiController, :batch
get "/stores/:org/:store/entries/*path", EntriesApiController, :show
```

**Step 3: Implement the action**

```elixir
def batch(conn, params) do
  with {:ok, paths} <- parse_batch_paths(params),
       {:ok, store} <- fetch_store(conn, params),
       :ok <- verify_read_permission(conn.assigns.store_token) do
    %{entries: entries, missing: missing} = Dust.Sync.get_many_entries(store.id, paths)
    json(conn, %{
      "entries" => render_batch_entries(entries),
      "missing" => missing
    })
  else
    {:error, {:invalid_params, detail}} ->
      conn |> put_status(400) |> json(%{"error" => "invalid_params", "detail" => detail})

    # ... org/store/permission errors handled same as index/2 ...
  end
end

defp parse_batch_paths(%{"paths" => paths}) when is_list(paths) do
  cond do
    length(paths) > 1000 ->
      {:error, {:invalid_params, "maximum 1000 paths per batch"}}

    not Enum.all?(paths, &is_binary/1) ->
      {:error, {:invalid_params, "paths must be strings"}}

    true ->
      {:ok, paths}
  end
end

defp parse_batch_paths(_), do: {:error, {:invalid_params, "paths required"}}

defp render_batch_entries(entries) do
  Map.new(entries, fn {path, %{value: v, type: t, seq: s}} ->
    {path, %{"value" => v, "type" => t, "revision" => s}}
  end)
end
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(server): POST /api/stores/:org/:store/entries/batch`

---

### Task 11: End-to-end verification

**Files:** none modified.

**Step 1:** SDK full suite:
```bash
cd sdk/elixir && mix test
```
Expected: all green. Count should be ~14 more tests than Phase 1's 158 baseline (six range + four read_many + two range-sync-engine + two get_many-sync-engine-ish). Exact number will depend on which tests you wrote; ~172 total.

**Step 2:** Server targeted tests:
```bash
cd server && mix test test/dust_web/controllers/api/entries_api_controller_test.exs test/dust/sync_range_test.exs
```
Expected: all green.

**Step 3:** Server format check:
```bash
cd server && mix format --check-formatted
```
Expected: clean.

**Step 4: No commit needed** (verification-only task).

---

## Verification checklist

- [ ] `Dust.range/4` returns `%Dust.Page{}` with entries in `[from, to)`.
- [ ] `Dust.range/4` honors `:limit`, `:after`, `:order`, `:select: :entries | :keys`.
- [ ] `Dust.range/4` rejects `select: :prefixes` with `{:error, :unsupported_select}`.
- [ ] `Dust.range/4` with `from >= to` returns an empty page.
- [ ] `Dust.get_many/2` returns `%{path => value}`, omits missing paths.
- [ ] `Dust.get_many/2` unwraps FileRef values the same way `Dust.get/2` does.
- [ ] Memory and Ecto caches both implement `browse` with range AND `read_many/3`.
- [ ] `GET /api/stores/.../entries?from=X&to=Y` returns the same shape as enum.
- [ ] `GET /entries` with both pattern and from/to returns 400 `conflicting_params`.
- [ ] `GET /entries` with lopsided from/to returns 400 `invalid_params`.
- [ ] `POST /api/stores/.../entries/batch` returns `{"entries": ..., "missing": ...}`.
- [ ] Batch route ordering doesn't break the existing `/entries/*path` wildcard.
- [ ] `POST /entries/batch` with missing, empty, or too-many paths returns 400.
- [ ] No `try`/`rescue` anywhere in new code.
- [ ] All Phase 1 tests still pass (no regressions).

## Cross-SDK parity check

All new read features are expressible in SQL:

- `range` → `SELECT ... WHERE path >= ? AND path < ? [AND path > ?] ORDER BY path LIMIT ?`
- `get_many` → `SELECT ... WHERE path IN (?, ?, ...)` — standard SQL, trivially portable to Ruby/Python SQLite.

When the Ruby/Python SDKs are built, both features port to their local SQLite caches with no semantic changes — same column names, same `seq` semantics, same shapes.

## Process reminder (learned from Phase 1)

Three subagents in Phase 1 fabricated commit SHAs — their file changes persisted to the working tree but their `git commit` calls never landed. For Phase 2, the execution protocol is:

1. Subagent implements + runs tests + reports results.
2. Subagent does NOT commit.
3. Main session verifies via `git diff` and `git ls-files --others`, then commits from the main session.
4. Main session verifies the commit landed via `git log -1 --format='%H %s'`.

Every task in this plan assumes that flow. The "Commit" step in each task is done by the main session, not the subagent.
