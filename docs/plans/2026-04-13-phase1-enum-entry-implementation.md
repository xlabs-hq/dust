# Phase 1 — Enum/3, Entry/2, and HTTP Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Every task uses TDD: write the failing test first, verify it fails, implement minimally, verify it passes, commit.

**Goal:** Ship `Dust.enum/3` (paginated, projected, ordered), `Dust.entry/2` (metadata-bearing read), and matching HTTP endpoints as end-to-end features in the Elixir SDK and the Phoenix server.

**Architecture:** Extend the existing `Dust.Cache` behaviour with a new `read_entry/3` callback and enrich the existing `browse/3` callback options. Add two new public SDK functions that translate user-facing options to adapter calls. Mirror both via REST endpoints in the Phoenix server (`/api/stores/:org/:store/entries` for paginated enum, `/api/stores/:org/:store/entries/*path` for single-entry metadata reads). Ruby/Python SDKs are not built in this phase but the HTTP shapes are defined so they can consume them unchanged.

**Tech stack:** Elixir 1.15+, Phoenix 1.8, Ecto 3, existing `Dust.Cache.Memory` (GenServer-backed) and `Dust.Cache.Ecto` (SQLite via Ecto) adapters, existing `ApiTokenAuth` plug.

**Design reference:** `docs/plans/2026-04-13-kv-native-features-design.md` — "Phase 1 — Elixir SDK enumeration upgrade" and cross-SDK guidelines (reads-expressible-as-SQL, cache schema parity).

---

## Background the engineer needs

### Current shape of the cache

`Dust.Cache` (`sdk/elixir/lib/dust/cache.ex`) is a behaviour with two implementations:

- `Dust.Cache.Memory` — GenServer keyed by `{store, path}`, stores `{value, type, seq}` tuples.
- `Dust.Cache.Ecto` — Ecto-backed, each row is `{store, path, value (json), type, seq}`. Stores the max seq via a sentinel row at path `_dust:last_seq`.

Both already implement `browse/3` with ascending-only keyset pagination. Both receive opts `:pattern`, `:cursor`, `:limit`. The return shape is `{[{path, value, type, seq}], next_cursor | nil}`.

### Current shape of the public API

`Dust.enum/2` (`sdk/elixir/lib/dust.ex:28`) delegates to `Dust.SyncEngine.enum/2`, which calls `cache.read_all/3` and returns a flat `[{path, value}, ...]` list. It ignores metadata.

There is no `Dust.entry/2` today. `Dust.get/2` exists (`sdk/elixir/lib/dust.ex:18`) and returns `{:ok, value} | :miss`, stripping metadata.

### Path semantics

Paths are dot-delimited strings: `"users.alice.name"`. Glob matching uses `Dust.Protocol.Glob` after `String.split(path, ".")`. The plan restricts `delimiter:` to `"."` only and the codebase already enforces this structurally.

### HTTP auth

REST endpoints live under `scope "/api", DustWeb.Api` in `server/lib/dust_web/router.ex`, piped through `:api_auth` which includes `DustWeb.Plugs.ApiTokenAuth`. Tokens are store-scoped (Bearer `dust_tok_*`). The plug assigns `:store_token` and `:organization`. Look at `AuditApiController` and `ExportController` for the pattern of how controllers read the current store from conn assigns.

### Testing conventions (from server/AGENTS.md)

- Fixtures, not factories.
- `start_supervised!/1` for processes in tests.
- Never `Process.sleep`; use `Process.monitor` or `:sys.get_state` for sync.
- No `try`/`rescue` without explicit permission.
- Run `mix format` after edits, `mix precommit` when the phase is done.

### Single-file non-negotiables

- NO nested module definitions.
- One alias per line at top of file.
- `Logger.info` takes only a string — inline interpolation, never keyword metadata.
- Use `<.link navigate={}>`, never `live_redirect`.

---

## Scope of Phase 1

**In scope:**

1. New struct: `Dust.Page`
2. New struct: `Dust.Entry`
3. New cache callback: `read_entry/3`
4. Memory and Ecto adapter: implement `read_entry/3`
5. Memory and Ecto adapter: extend `browse/3` with `order: :desc | :asc`, `select: :entries | :keys | :prefixes`
6. New public SDK function: `Dust.enum/3`
7. New public SDK function: `Dust.entry/2`
8. New SyncEngine handlers: `{:enum_paged, pattern, opts}` and `{:entry, path}`
9. New HTTP endpoint: `GET /api/stores/:org/:store/entries`
10. New HTTP endpoint: `GET /api/stores/:org/:store/entries/*path` (wildcard to accept dotted paths verbatim)
11. Routing + tests

**Out of scope for Phase 1 (deferred to later phases):**

- `range/4`, `get_many/2` (Phase 2)
- `include_current` bootstrap watch (Phase 3)
- TypeScript/CLI parity (Phase 4)
- CAS `if_match` (Phase 5)
- `enum/2` remains unchanged. It is NOT refactored to call `enum/3`. Two shapes coexist.

---

## Semantics to pin down

### `Dust.enum/3` options

```elixir
Dust.enum(store, pattern, opts)
# => %Dust.Page{items: [...], next_cursor: nil | String.t()}
```

Options:

- `:limit` — default `50`, max `1000`
- `:after` — opaque cursor string (previously received as `next_cursor`)
- `:order` — `:asc` (default) or `:desc`
- `:select` — `:entries` (default), `:keys`, or `:prefixes`

Item shapes per projection:

- `:entries` → `%Dust.Entry{path, value, type, revision}`
- `:keys` → `String.t()` (just the path)
- `:prefixes` → `String.t()` (unique path prefixes, see below)

### `select: :prefixes` exact semantics

`:prefixes` requires the pattern to end in `.**` (or be `**`, meaning the empty prefix).

- Given paths `users.alice.name`, `users.alice.email`, `users.bob.name`
- `enum(store, "**", select: :prefixes)` → `%Page{items: ["users"]}`
- `enum(store, "users.**", select: :prefixes)` → `%Page{items: ["users.alice", "users.bob"]}`

Algorithm: compute the literal prefix before `.**` (empty string if pattern is `**`). For each matching path, take the literal prefix plus the next segment after it. Deduplicate, sort lexicographically (asc or desc per `:order`).

Unsupported pattern forms (anything without trailing `.**` or `**`) → `{:error, :invalid_pattern_for_prefixes}`. Return this from `Dust.enum/3` directly, do not crash.

### `Dust.entry/2`

```elixir
Dust.entry(store, path)
# => {:ok, %Dust.Entry{path, value, type, revision}} | {:error, :not_found}
```

`revision` is the entry's `seq`. For Phase 1 `entry/2` returns leaf entries only. Calling it on a subtree path returns `{:error, :not_found}` — subtree assembly and subtree revision are out of scope for Phase 1. (The design doc says `Dust.entry/2` on a subtree returns a max-descendant-seq revision, but that logic lives only on the server today; we defer it to a later phase or fetch it via HTTP when Ruby/Python need it.)

### HTTP endpoint shapes

```
GET /api/stores/:org/:store/entries?pattern=users.**&limit=50&after=X&order=asc&select=entries
Authorization: Bearer dust_tok_...

200 OK
{
  "items": [
    {"path": "users.alice.name", "value": "Alice", "type": "string", "revision": 7},
    ...
  ],
  "next_cursor": "users.alice.name" | null
}
```

For `select=keys`:
```json
{"items": ["users.alice.name", "users.alice.email"], "next_cursor": null}
```

For `select=prefixes`:
```json
{"items": ["users.alice", "users.bob"], "next_cursor": null}
```

```
GET /api/stores/:org/:store/entries/users.alice.name
Authorization: Bearer dust_tok_...

200 OK
{"path": "users.alice.name", "value": "Alice", "type": "string", "revision": 7}

404 Not Found
{"error": "not_found"}
```

Invalid params return `400` with `{"error": "invalid_params", "detail": "..."}`.

---

## Task list

### Task 1: Create `Dust.Page` struct

**Files:**
- Create: `sdk/elixir/lib/dust/page.ex`
- Create: `sdk/elixir/test/dust/page_test.exs`

**Step 1: Write the failing test**

```elixir
# sdk/elixir/test/dust/page_test.exs
defmodule Dust.PageTest do
  use ExUnit.Case, async: true

  test "new/1 builds a page with items and nil cursor" do
    page = Dust.Page.new(items: [1, 2, 3])
    assert page.items == [1, 2, 3]
    assert page.next_cursor == nil
  end

  test "new/1 accepts next_cursor" do
    page = Dust.Page.new(items: [1], next_cursor: "x")
    assert page.next_cursor == "x"
  end

  test "enumerates via Enumerable" do
    page = Dust.Page.new(items: [1, 2, 3])
    assert Enum.to_list(page) == [1, 2, 3]
    assert Enum.count(page) == 3
  end
end
```

**Step 2: Run test**

```bash
cd sdk/elixir && mix test test/dust/page_test.exs
```
Expected: FAIL — `Dust.Page` undefined.

**Step 3: Implement**

```elixir
# sdk/elixir/lib/dust/page.ex
defmodule Dust.Page do
  @moduledoc "A page of results from `Dust.enum/3` or `Dust.range/4`."

  @type item :: term()
  @type t :: %__MODULE__{items: [item()], next_cursor: String.t() | nil}

  defstruct items: [], next_cursor: nil

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      items: Keyword.get(opts, :items, []),
      next_cursor: Keyword.get(opts, :next_cursor)
    }
  end

  defimpl Enumerable do
    def count(page), do: {:ok, length(page.items)}
    def member?(page, value), do: {:ok, Enum.member?(page.items, value)}
    def reduce(page, acc, fun), do: Enumerable.List.reduce(page.items, acc, fun)

    def slice(page) do
      size = length(page.items)

      {:ok, size,
       fn start, length, step ->
         page.items
         |> Enum.drop(start)
         |> Enum.take_every(step)
         |> Enum.take(length)
       end}
    end
  end
end
```

**Step 4: Run test, expect PASS**

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/page.ex sdk/elixir/test/dust/page_test.exs
git commit -m "feat(sdk): add Dust.Page struct"
```

---

### Task 2: Create `Dust.Entry` struct

**Files:**
- Create: `sdk/elixir/lib/dust/entry.ex`
- Create: `sdk/elixir/test/dust/entry_test.exs`

**Step 1: Write the failing test**

```elixir
# sdk/elixir/test/dust/entry_test.exs
defmodule Dust.EntryTest do
  use ExUnit.Case, async: true

  test "new/1 builds an entry with revision from seq" do
    entry = Dust.Entry.new(path: "a.b", value: 1, type: "integer", revision: 42)
    assert entry.path == "a.b"
    assert entry.value == 1
    assert entry.type == "integer"
    assert entry.revision == 42
  end
end
```

**Step 2: Run** — FAIL.

**Step 3: Implement**

```elixir
# sdk/elixir/lib/dust/entry.ex
defmodule Dust.Entry do
  @moduledoc "A single cached entry with metadata."

  @type t :: %__MODULE__{
          path: String.t(),
          value: term(),
          type: String.t(),
          revision: integer()
        }

  defstruct [:path, :value, :type, :revision]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      path: Keyword.fetch!(opts, :path),
      value: Keyword.fetch!(opts, :value),
      type: Keyword.fetch!(opts, :type),
      revision: Keyword.fetch!(opts, :revision)
    }
  end
end
```

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/entry.ex sdk/elixir/test/dust/entry_test.exs
git commit -m "feat(sdk): add Dust.Entry struct"
```

---

### Task 3: Add `read_entry/3` callback to `Dust.Cache` behaviour

**Files:**
- Modify: `sdk/elixir/lib/dust/cache.ex`

No test — this is a behaviour declaration. Adapter tests in Tasks 4 and 5 verify implementations.

**Step 1: Edit**

Add this line after the existing `read/3` callback:

```elixir
@callback read_entry(target :: term(), store :: String.t(), path :: String.t()) ::
            {:ok, {value :: term(), type :: String.t(), seq :: integer()}} | :miss
```

**Do NOT** add `read_entry: 3` to `@optional_callbacks` — unlike `count/2` and `browse/3`, `read_entry/3` is called unconditionally by `SyncEngine.entry/2` and every adapter in this phase implements it, so it must be required.

**Step 2: Verify it compiles**

```bash
cd sdk/elixir && mix compile
```
Expected: compile succeeds, may warn about missing implementations (will be fixed in next tasks).

**Step 3: Commit**

```bash
git add sdk/elixir/lib/dust/cache.ex
git commit -m "feat(sdk): add read_entry/3 to Dust.Cache behaviour"
```

---

### Task 4: Implement `read_entry/3` in `Dust.Cache.Memory`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/memory.ex`
- Modify or create: `sdk/elixir/test/dust/cache/memory_test.exs`

**Step 1: Failing test**

```elixir
test "read_entry/3 returns {value, type, seq} for present keys" do
  {:ok, pid} = start_supervised({Dust.Cache.Memory, name: :mem_read_entry})
  :ok = Dust.Cache.Memory.write(pid, "s1", "a.b", "hello", "string", 7)
  assert Dust.Cache.Memory.read_entry(pid, "s1", "a.b") == {:ok, {"hello", "string", 7}}
end

test "read_entry/3 returns :miss for absent keys" do
  {:ok, pid} = start_supervised({Dust.Cache.Memory, name: :mem_read_entry_miss})
  assert Dust.Cache.Memory.read_entry(pid, "s1", "nope") == :miss
end
```

**Step 2: Run — FAIL** (`function read_entry/3 undefined`).

**Step 3: Implement** — add the callback impl and handle_call:

```elixir
@impl Dust.Cache
def read_entry(pid, store, path) do
  GenServer.call(pid, {:read_entry, store, path})
end

# in handle_call region:
@impl true
def handle_call({:read_entry, store, path}, _from, state) do
  case Map.get(state.entries, {store, path}) do
    nil -> {:reply, :miss, state}
    {value, type, seq} -> {:reply, {:ok, {value, type, seq}}, state}
  end
end
```

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/memory.ex sdk/elixir/test/dust/cache/memory_test.exs
git commit -m "feat(sdk): Memory cache implements read_entry/3"
```

---

### Task 5: Implement `read_entry/3` in `Dust.Cache.Ecto`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Modify: `sdk/elixir/test/dust/cache/ecto_test.exs` (or create)

**Step 1: Failing test** — use the same shape as Task 4 but with the Ecto repo fixture. Look at existing Ecto tests in the repo for the repo setup pattern.

```elixir
test "read_entry/3 returns full metadata", %{repo: repo} do
  :ok = Dust.Cache.Ecto.write(repo, "s1", "a.b", "hello", "string", 7)
  assert Dust.Cache.Ecto.read_entry(repo, "s1", "a.b") == {:ok, {"hello", "string", 7}}
end

test "read_entry/3 returns :miss for absent", %{repo: repo} do
  assert Dust.Cache.Ecto.read_entry(repo, "s1", "nope") == :miss
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement** — add after the existing `read/3`:

```elixir
@impl Dust.Cache
def read_entry(repo, store, path) do
  query =
    from(c in CacheEntry,
      where: c.store == ^store and c.path == ^path,
      select: {c.value, c.type, c.seq}
    )

  case repo.one(query) do
    nil -> :miss
    {json, type, seq} -> {:ok, {Jason.decode!(json), type, seq}}
  end
end
```

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/ecto.ex sdk/elixir/test/dust/cache/ecto_test.exs
git commit -m "feat(sdk): Ecto cache implements read_entry/3"
```

---

### Task 6: Add `:entry` handler to `Dust.SyncEngine`

**Files:**
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs` (or create)

**Step 1: Failing test**

```elixir
test "entry/2 returns {:ok, %Dust.Entry{}} for present leaf" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a.b", "hello", "string")
  assert {:ok, %Dust.Entry{path: "a.b", value: "hello", type: "string", revision: rev}} =
           Dust.SyncEngine.entry(store, "a.b")
  assert is_integer(rev)
end

test "entry/2 returns {:error, :not_found} for missing path" do
  store = start_test_store()
  assert Dust.SyncEngine.entry(store, "nope") == {:error, :not_found}
end
```

(`start_test_store` is an existing helper — reuse whatever pattern other SyncEngine tests use.)

**Step 2: Run — FAIL.**

**Step 3: Implement**

In the public API section of `sync_engine.ex`:

```elixir
def entry(store, path) do
  GenServer.call(via(store), {:entry, path})
end
```

In the handle_call region (near the existing `{:enum, pattern}` handler around line 341):

```elixir
@impl true
def handle_call({:entry, path}, _from, state) do
  reply =
    case state.cache.read_entry(state.cache_target, state.store, path) do
      {:ok, {value, type, seq}} ->
        {:ok, Dust.Entry.new(path: path, value: value, type: type, revision: seq)}

      :miss ->
        {:error, :not_found}
    end

  {:reply, reply, state}
end
```

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/sync_engine.ex sdk/elixir/test/dust/sync_engine_test.exs
git commit -m "feat(sdk): SyncEngine.entry/2 returns Dust.Entry with revision"
```

---

### Task 7: Add `Dust.entry/2` public delegate

**Files:**
- Modify: `sdk/elixir/lib/dust.ex`
- Modify: `sdk/elixir/test/dust_test.exs` (or create)

**Step 1: Failing test**

```elixir
test "Dust.entry/2 delegates to SyncEngine" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  assert {:ok, %Dust.Entry{path: "a", value: 1, revision: _}} = Dust.entry(store, "a")
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement** — add after `defdelegate get`:

```elixir
defdelegate entry(store, path), to: Dust.SyncEngine
```

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust.ex sdk/elixir/test/dust_test.exs
git commit -m "feat(sdk): expose Dust.entry/2"
```

---

### Task 8: Memory browse — `order: :desc`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/memory.ex`
- Modify: `sdk/elixir/test/dust/cache/memory_test.exs`

**Step 1: Failing test**

```elixir
test "browse with order: :desc returns entries in reverse lex order" do
  {:ok, pid} = start_supervised({Dust.Cache.Memory, name: :mem_desc})
  for k <- ~w(a b c d), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)

  {page, _} = Dust.Cache.Memory.browse(pid, "s", limit: 10, order: :desc)
  assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(d c b a)
end

test "browse with order: :desc and cursor drops entries >= cursor" do
  {:ok, pid} = start_supervised({Dust.Cache.Memory, name: :mem_desc_cursor})
  for k <- ~w(a b c d), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)

  {page, _} = Dust.Cache.Memory.browse(pid, "s", limit: 10, order: :desc, cursor: "c")
  # desc + cursor "c" means next items are strictly less than "c"
  assert Enum.map(page, fn {p, _, _, _} -> p end) == ~w(b a)
end
```

**Step 2: Run — FAIL** (order/desc not respected).

**Step 3: Implement**

Rewrite `handle_call({:browse, ...})` to honor `:order`:

```elixir
@impl true
def handle_call({:browse, store, opts}, _from, state) do
  pattern = Keyword.get(opts, :pattern, "**")
  cursor = Keyword.get(opts, :cursor)
  limit = Keyword.get(opts, :limit, 50)
  order = Keyword.get(opts, :order, :asc)

  compiled = Dust.Protocol.Glob.compile(pattern)

  entries =
    state.entries
    |> Enum.filter(fn {{s, path}, _} ->
      s == store and Dust.Protocol.Glob.match?(compiled, String.split(path, "."))
    end)
    |> Enum.map(fn {{_s, path}, {value, type, seq}} -> {path, value, type, seq} end)
    |> Enum.sort_by(fn {p, _, _, _} -> p end, sort_direction(order))

  entries = apply_cursor(entries, cursor, order)

  page = Enum.take(entries, limit)

  next_cursor =
    if length(page) < limit or page == [] do
      nil
    else
      {last_path, _, _, _} = List.last(page)
      last_path
    end

  {:reply, {page, next_cursor}, state}
end

defp sort_direction(:asc), do: :asc
defp sort_direction(:desc), do: :desc

defp apply_cursor(entries, nil, _order), do: entries
defp apply_cursor(entries, cursor, :asc), do: Enum.drop_while(entries, fn {p, _, _, _} -> p <= cursor end)
defp apply_cursor(entries, cursor, :desc), do: Enum.drop_while(entries, fn {p, _, _, _} -> p >= cursor end)
```

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/memory.ex sdk/elixir/test/dust/cache/memory_test.exs
git commit -m "feat(sdk): Memory browse supports order: :desc"
```

---

### Task 9: Memory browse — `select: :keys`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/memory.ex`
- Modify: `sdk/elixir/test/dust/cache/memory_test.exs`

**Step 1: Failing test**

```elixir
test "browse with select: :keys returns only paths" do
  {:ok, pid} = start_supervised({Dust.Cache.Memory, name: :mem_keys})
  for k <- ~w(a b c), do: :ok = Dust.Cache.Memory.write(pid, "s", k, k, "string", 1)

  {items, _} = Dust.Cache.Memory.browse(pid, "s", select: :keys, limit: 10)
  assert items == ~w(a b c)
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

After the page is computed but before returning, apply projection:

```elixir
select = Keyword.get(opts, :select, :entries)
projected = project_page(page, select, pattern)

{:reply, {projected, next_cursor}, state}
```

And add helper:

```elixir
defp project_page(page, :entries, _pattern), do: page
defp project_page(page, :keys, _pattern), do: Enum.map(page, fn {p, _, _, _} -> p end)
defp project_page(page, :prefixes, pattern), do: prefixes_of(page, pattern)
# prefixes_of/2 added in Task 10
```

Leave `prefixes_of/2` undefined for now — Task 10 adds it.

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/memory.ex sdk/elixir/test/dust/cache/memory_test.exs
git commit -m "feat(sdk): Memory browse supports select: :keys"
```

---

### Task 10: Memory browse — `select: :prefixes`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/memory.ex`
- Modify: `sdk/elixir/test/dust/cache/memory_test.exs`

**Step 1: Failing tests**

```elixir
test "browse with select: :prefixes and pattern ** returns top-level segments" do
  {:ok, pid} = start_supervised({Dust.Cache.Memory, name: :mem_pref_top})
  for p <- ~w(users.alice.name users.bob.name posts.hi), do: :ok = Dust.Cache.Memory.write(pid, "s", p, 1, "integer", 1)

  {items, _} = Dust.Cache.Memory.browse(pid, "s", pattern: "**", select: :prefixes, limit: 10)
  assert items == ~w(posts users)
end

test "browse with select: :prefixes and pattern 'users.**' returns next-segment prefixes" do
  {:ok, pid} = start_supervised({Dust.Cache.Memory, name: :mem_pref_sub})
  for p <- ~w(users.alice.name users.alice.email users.bob.name), do: :ok = Dust.Cache.Memory.write(pid, "s", p, 1, "integer", 1)

  {items, _} = Dust.Cache.Memory.browse(pid, "s", pattern: "users.**", select: :prefixes, limit: 10)
  assert items == ~w(users.alice users.bob)
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

```elixir
defp prefixes_of(page, pattern) do
  literal_prefix = literal_prefix_of(pattern)

  page
  |> Enum.map(fn {p, _, _, _} -> extract_prefix(p, literal_prefix) end)
  |> Enum.reject(&is_nil/1)
  |> Enum.uniq()
  |> Enum.sort()
end

defp literal_prefix_of("**"), do: ""
defp literal_prefix_of(pattern) do
  case String.split(pattern, ".**", parts: 2) do
    [prefix, ""] -> prefix
    _ -> raise ArgumentError, "select: :prefixes requires pattern ending in .** or ** (got #{inspect(pattern)})"
  end
end

defp extract_prefix(path, "") do
  case String.split(path, ".", parts: 2) do
    [seg | _] -> seg
    [] -> nil
  end
end

defp extract_prefix(path, literal) do
  prefix_with_dot = literal <> "."
  if String.starts_with?(path, prefix_with_dot) do
    rest = String.replace_prefix(path, prefix_with_dot, "")
    [next_seg | _] = String.split(rest, ".", parts: 2)
    literal <> "." <> next_seg
  end
end
```

Note: if `literal_prefix_of/1` raises, the public `Dust.enum/3` will catch it — we wire that up in Task 14. Inside the cache it's OK to raise for malformed patterns; the public API is the layer that converts to `{:error, :invalid_pattern_for_prefixes}`.

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/memory.ex sdk/elixir/test/dust/cache/memory_test.exs
git commit -m "feat(sdk): Memory browse supports select: :prefixes"
```

---

### Task 11: Ecto browse — `order: :desc`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Modify: `sdk/elixir/test/dust/cache/ecto_test.exs`

**Step 1: Failing test** — mirror the Task 8 test shape against the Ecto adapter.

**Step 2: Run — FAIL.**

**Step 3: Implement**

Modify `browse/3` to read `:order` and switch the `order_by` clause:

```elixir
order = Keyword.get(opts, :order, :asc)

query =
  from(c in CacheEntry,
    where: c.store == ^store and c.path != ^@seq_sentinel_path,
    order_by: [{^order, c.path}],
    limit: ^(limit + 1),
    select: {c.path, c.value, c.type, c.seq}
  )

query =
  if cursor do
    case order do
      :asc -> from(c in query, where: c.path > ^cursor)
      :desc -> from(c in query, where: c.path < ^cursor)
    end
  else
    query
  end
```

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/ecto.ex sdk/elixir/test/dust/cache/ecto_test.exs
git commit -m "feat(sdk): Ecto browse supports order: :desc"
```

---

### Task 12: Ecto browse — `select: :keys`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Modify: `sdk/elixir/test/dust/cache/ecto_test.exs`

**Step 1: Failing test** — mirror Task 9 test, shape for Ecto.

**Step 2: Run — FAIL.**

**Step 3: Implement**

Read `:select` and when `:keys`, change the `select:` clause to `c.path` only (still need seq/type for cursor? No — cursor is based on path only). Actually simpler: keep the existing query shape, skip JSON-decoding values, then project to strings at the end:

```elixir
select = Keyword.get(opts, :select, :entries)

# ... query unchanged ...

rows = repo.all(query)

filtered = # (unchanged glob filter)

# Decode values only if we need them
decoded =
  case select do
    :keys ->
      Enum.map(filtered, fn {path, _json, _type, _seq} -> {path, nil, nil, nil} end)

    _ ->
      Enum.map(filtered, fn {path, json, type, seq} ->
        {path, Jason.decode!(json), type, seq}
      end)
  end

page = Enum.take(decoded, limit)

next_cursor =
  if length(decoded) > limit do
    {last_path, _, _, _} = List.last(page)
    last_path
  else
    nil
  end

projected = project_page(page, select, pattern)

{projected, next_cursor}
```

Add `project_page/3` and `prefixes_of/2` / helpers — **copy them verbatim** from the Memory adapter (Tasks 9 and 10) into the Ecto module. Yes this is duplication, and yes it's deliberate for Phase 1 — we could refactor them into a shared module later but KEEPING THE ADAPTERS SELF-CONTAINED is the current convention and we're not going to refactor shared code across adapters in a feature phase.

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/ecto.ex sdk/elixir/test/dust/cache/ecto_test.exs
git commit -m "feat(sdk): Ecto browse supports select: :keys"
```

---

### Task 13: Ecto browse — `select: :prefixes`

**Files:**
- Modify: `sdk/elixir/lib/dust/cache/ecto.ex`
- Modify: `sdk/elixir/test/dust/cache/ecto_test.exs`

**Step 1: Failing test** — mirror Task 10 against Ecto.

**Step 2: Run — FAIL.**

**Step 3: Implement** — the prefix helpers were copied in Task 12. Should work automatically once `project_page(_, :prefixes, _)` is called. Verify by running the test.

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/cache/ecto.ex sdk/elixir/test/dust/cache/ecto_test.exs
git commit -m "feat(sdk): Ecto browse supports select: :prefixes"
```

---

### Task 14: SyncEngine — `:enum_paged` handler

**Files:**
- Modify: `sdk/elixir/lib/dust/sync_engine.ex`
- Modify: `sdk/elixir/test/dust/sync_engine_test.exs`

**Step 1: Failing test**

```elixir
test "enum/3 returns a Dust.Page of entries" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  Dust.SyncEngine.seed_entry(store, "b", 2, "integer")

  assert %Dust.Page{items: items, next_cursor: nil} =
           Dust.SyncEngine.enum(store, "**", limit: 10)

  paths = Enum.map(items, & &1.path)
  assert paths == ["a", "b"]
  assert Enum.all?(items, fn e -> match?(%Dust.Entry{}, e) end)
end

test "enum/3 with select: :keys returns a Page of path strings" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  Dust.SyncEngine.seed_entry(store, "b", 2, "integer")

  assert %Dust.Page{items: ~w(a b)} = Dust.SyncEngine.enum(store, "**", select: :keys, limit: 10)
end

test "enum/3 with invalid pattern for :prefixes returns error tuple" do
  store = start_test_store()
  assert Dust.SyncEngine.enum(store, "a.*.b", select: :prefixes) == {:error, :invalid_pattern_for_prefixes}
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

Add a 3-arity `enum` public fn next to the existing 2-arity one:

```elixir
def enum(store, pattern, opts) when is_list(opts) do
  GenServer.call(via(store), {:enum_paged, pattern, opts})
end
```

Add handler:

```elixir
@impl true
def handle_call({:enum_paged, pattern, opts}, _from, state) do
  limit = opts |> Keyword.get(:limit, 50) |> min(1000)
  order = Keyword.get(opts, :order, :asc)
  select = Keyword.get(opts, :select, :entries)
  cursor = Keyword.get(opts, :after)

  browse_opts = [
    pattern: pattern,
    limit: limit,
    order: order,
    select: select,
    cursor: cursor
  ]

  reply =
    try do
      {items, next_cursor} = state.cache.browse(state.cache_target, state.store, browse_opts)
      mapped = wrap_items(items, select)
      {:ok, Dust.Page.new(items: mapped, next_cursor: next_cursor)}
    rescue
      ArgumentError -> {:error, :invalid_pattern_for_prefixes}
    end

  case reply do
    {:ok, page} -> {:reply, page, state}
    {:error, _} = err -> {:reply, err, state}
  end
end

defp wrap_items(items, :entries) do
  Enum.map(items, fn {path, value, type, seq} ->
    Dust.Entry.new(path: path, value: value, type: type, revision: seq)
  end)
end

defp wrap_items(items, :keys), do: items
defp wrap_items(items, :prefixes), do: items
```

**IMPORTANT NOTE FOR THE ENGINEER:** The server-wide rule is NO `try`/`rescue` without explicit permission. THIS PLAN AUTHORIZES the `rescue ArgumentError` here **only** to convert the cache adapter's invalid-pattern exception into an error tuple. Do not extend the `rescue` to other exception types. If the engineer prefers an alternative (e.g., validate the pattern in `enum/3` before calling the cache so no rescue is needed), that is preferred. See Task 14b below as a cleaner alternative.

### Task 14b (preferred alternative): Validate pattern up-front, no rescue

Instead of catching `ArgumentError`:

```elixir
defp validate_enum_opts(pattern, opts) do
  case Keyword.get(opts, :select, :entries) do
    :prefixes ->
      if valid_prefix_pattern?(pattern), do: :ok, else: {:error, :invalid_pattern_for_prefixes}

    _ ->
      :ok
  end
end

defp valid_prefix_pattern?("**"), do: true
defp valid_prefix_pattern?(pattern), do: String.ends_with?(pattern, ".**")
```

Then in the handler:

```elixir
with :ok <- validate_enum_opts(pattern, opts),
     {items, next_cursor} <- state.cache.browse(state.cache_target, state.store, browse_opts) do
  page = Dust.Page.new(items: wrap_items(items, Keyword.get(opts, :select, :entries)), next_cursor: next_cursor)
  {:reply, page, state}
else
  {:error, _} = err -> {:reply, err, state}
end
```

**Use 14b, not 14a.** Remove the raise from `literal_prefix_of/1` in Tasks 10/13 since we now validate up-front. (Keep the raise as a safety net if you like, but it should become unreachable through the public API.)

**Step 4:** Run — PASS.

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust/sync_engine.ex sdk/elixir/test/dust/sync_engine_test.exs
git commit -m "feat(sdk): SyncEngine.enum/3 returns paged Dust.Page"
```

---

### Task 15: `Dust.enum/3` public delegate

**Files:**
- Modify: `sdk/elixir/lib/dust.ex`
- Modify: `sdk/elixir/test/dust_test.exs`

**Step 1: Failing test**

```elixir
test "Dust.enum/3 returns a Page" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  assert %Dust.Page{items: [%Dust.Entry{}]} = Dust.enum(store, "**", limit: 10)
end

test "Dust.enum/2 still returns the flat list (compat)" do
  store = start_test_store()
  Dust.SyncEngine.seed_entry(store, "a", 1, "integer")
  assert [{"a", 1}] = Dust.enum(store, "**")
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

In `sdk/elixir/lib/dust.ex`, alongside the existing `defdelegate enum(store, pattern), to: Dust.SyncEngine`:

```elixir
defdelegate enum(store, pattern, opts), to: Dust.SyncEngine
```

**Step 4:** Run — PASS (both tests).

**Step 5: Commit**

```bash
git add sdk/elixir/lib/dust.ex sdk/elixir/test/dust_test.exs
git commit -m "feat(sdk): expose Dust.enum/3"
```

---

### Task 16: HTTP endpoint — `GET /api/stores/:org/:store/entries`

**Files:**
- Create: `server/lib/dust_web/controllers/api/entries_api_controller.ex`
- Create: `server/test/dust_web/controllers/api/entries_api_controller_test.exs`
- Modify: `server/lib/dust_web/router.ex` (add route)

**Reference files:**
- `server/lib/dust_web/controllers/api/audit_api_controller.ex` — pattern for authenticated API controllers
- `server/lib/dust_web/controllers/api/export_controller.ex` — pattern for reading current store entries (NOT the audit log)
- `server/lib/dust_web/plugs/api_token_auth.ex` — how conn assigns are set

**Step 1: Failing test**

```elixir
# server/test/dust_web/controllers/api/entries_api_controller_test.exs
defmodule DustWeb.Api.EntriesApiControllerTest do
  use DustWeb.ConnCase, async: true

  import Dust.StoresFixtures
  import Dust.SyncFixtures  # or whatever exists for seeding entries

  setup %{conn: conn} do
    # Use existing fixtures. Mirror audit_api_controller_test setup.
    org = organization_fixture()
    store = store_fixture(organization: org)
    token = api_token_fixture(store: store)

    # Seed some entries via the same path the WebSocket write uses
    seed_entry(store, "users.alice.name", "Alice")
    seed_entry(store, "users.alice.email", "a@b.c")
    seed_entry(store, "users.bob.name", "Bob")

    conn = put_req_header(conn, "authorization", "Bearer #{token.plaintext}")
    %{conn: conn, org: org, store: store}
  end

  test "GET /entries returns paginated entries", %{conn: conn, org: org, store: store} do
    conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?pattern=users.**&limit=10")

    body = json_response(conn, 200)
    assert length(body["items"]) == 3
    assert hd(body["items"])["path"] =~ "users."
    assert hd(body["items"])["revision"] |> is_integer()
    assert is_integer(hd(body["items"])["revision"])
  end

  test "GET /entries?select=keys returns list of path strings", %{conn: conn, org: org, store: store} do
    conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?pattern=users.**&select=keys")
    body = json_response(conn, 200)
    assert body["items"] == ["users.alice.email", "users.alice.name", "users.bob.name"]
  end

  test "GET /entries?select=prefixes returns unique next-segment prefixes", %{conn: conn, org: org, store: store} do
    conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?pattern=users.**&select=prefixes")
    body = json_response(conn, 200)
    assert body["items"] == ["users.alice", "users.bob"]
  end

  test "GET /entries?select=prefixes with invalid pattern returns 400", %{conn: conn, org: org, store: store} do
    conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?pattern=users.*&select=prefixes")
    assert %{"error" => "invalid_pattern_for_prefixes"} = json_response(conn, 400)
  end

  test "GET /entries paginates via next_cursor", %{conn: conn, org: org, store: store} do
    conn1 = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?pattern=users.**&select=keys&limit=1")
    body1 = json_response(conn1, 200)
    assert length(body1["items"]) == 1
    assert body1["next_cursor"] != nil

    conn2 = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries?pattern=users.**&select=keys&limit=1&after=#{body1["next_cursor"]}")
    body2 = json_response(conn2, 200)
    assert body2["items"] != body1["items"]
  end
end
```

**Step 2: Run — FAIL** (route undefined, or 404).

**Step 3: Implement the controller**

```elixir
# server/lib/dust_web/controllers/api/entries_api_controller.ex
defmodule DustWeb.Api.EntriesApiController do
  use DustWeb, :controller

  alias Dust.Sync

  def index(conn, params) do
    store = conn.assigns.store_token.store

    with {:ok, opts} <- parse_opts(params),
         {:ok, page} <- Sync.enum_entries(store, opts[:pattern], Keyword.drop(opts, [:pattern])) do
      json(conn, render_page(page))
    else
      {:error, :invalid_pattern_for_prefixes} ->
        conn |> put_status(400) |> json(%{"error" => "invalid_pattern_for_prefixes"})

      {:error, {:invalid_params, detail}} ->
        conn |> put_status(400) |> json(%{"error" => "invalid_params", "detail" => detail})
    end
  end

  defp parse_opts(params) do
    with {:ok, pattern} <- parse_pattern(params),
         {:ok, limit} <- parse_limit(params),
         {:ok, order} <- parse_order(params),
         {:ok, select} <- parse_select(params) do
      opts = [
        pattern: pattern,
        limit: limit,
        order: order,
        select: select
      ]

      opts =
        case params["after"] do
          nil -> opts
          cursor when is_binary(cursor) -> Keyword.put(opts, :after, cursor)
        end

      {:ok, opts}
    end
  end

  defp parse_pattern(%{"pattern" => p}) when is_binary(p), do: {:ok, p}
  defp parse_pattern(_), do: {:ok, "**"}

  defp parse_limit(%{"limit" => l}) do
    case Integer.parse(to_string(l)) do
      {n, ""} when n > 0 and n <= 1000 -> {:ok, n}
      _ -> {:error, {:invalid_params, "limit must be 1..1000"}}
    end
  end
  defp parse_limit(_), do: {:ok, 50}

  defp parse_order(%{"order" => "desc"}), do: {:ok, :desc}
  defp parse_order(%{"order" => "asc"}), do: {:ok, :asc}
  defp parse_order(%{"order" => other}), do: {:error, {:invalid_params, "order=#{other}"}}
  defp parse_order(_), do: {:ok, :asc}

  defp parse_select(%{"select" => "keys"}), do: {:ok, :keys}
  defp parse_select(%{"select" => "prefixes"}), do: {:ok, :prefixes}
  defp parse_select(%{"select" => "entries"}), do: {:ok, :entries}
  defp parse_select(%{"select" => other}), do: {:error, {:invalid_params, "select=#{other}"}}
  defp parse_select(_), do: {:ok, :entries}

  defp render_page(%{items: items, next_cursor: cursor}) do
    %{"items" => Enum.map(items, &render_item/1), "next_cursor" => cursor}
  end

  defp render_item(%{path: p, value: v, type: t, revision: r}) do
    %{"path" => p, "value" => v, "type" => t, "revision" => r}
  end

  defp render_item(path) when is_binary(path), do: path
end
```

**Step 4: Implement `Dust.Sync.enum_entries/3` on the server side**

The server must have a function that, given a store, mirrors what `Dust.SyncEngine.enum/3` does in the SDK but reads from the **authoritative** server storage, not a cache. Look at how `ExportController` reads all entries for a store and mirror that shape. You'll likely add a function to `server/lib/dust/sync.ex`:

```elixir
# server/lib/dust/sync.ex
def enum_entries(store, pattern, opts) do
  # 1. Validate pattern for :prefixes if needed (same validate_enum_opts/2 as SDK)
  # 2. Read entries from wherever the server currently reads them (see ExportController for precedent)
  # 3. Apply glob pattern filter
  # 4. Sort by path (asc or desc per order)
  # 5. Apply cursor (after)
  # 6. Apply limit
  # 7. Project per select (:entries | :keys | :prefixes)
  # 8. Return {:ok, %{items: [...], next_cursor: ...}}
end
```

This does NOT go through the Elixir SDK — it reads the server's local SQLite directly. Look at `ExportController` (`server/lib/dust_web/controllers/api/export_controller.ex`) and trace how it pulls entries from storage. Reuse that read path.

**Step 5: Add route**

In `server/lib/dust_web/router.ex`, inside the `scope "/api", DustWeb.Api` block, near the audit log route (`get "/stores/:org/:store/log", AuditApiController, :index`), add:

```elixir
get "/stores/:org/:store/entries", EntriesApiController, :index
```

**Step 6:** Run the controller test — PASS.

**Step 7: Commit**

```bash
git add server/lib/dust_web/controllers/api/entries_api_controller.ex \
        server/test/dust_web/controllers/api/entries_api_controller_test.exs \
        server/lib/dust/sync.ex \
        server/lib/dust_web/router.ex
git commit -m "feat(server): GET /api/stores/:org/:store/entries paginated enum"
```

---

### Task 17: HTTP endpoint — `GET /api/stores/:org/:store/entries/*path`

**Files:**
- Modify: `server/lib/dust_web/controllers/api/entries_api_controller.ex` (add `:show` action)
- Modify: `server/test/dust_web/controllers/api/entries_api_controller_test.exs` (add tests)
- Modify: `server/lib/dust_web/router.ex` (add route with wildcard)

**Step 1: Failing test**

```elixir
test "GET /entries/:path returns entry with revision", %{conn: conn, org: org, store: store} do
  conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries/users.alice.name")
  body = json_response(conn, 200)
  assert body["path"] == "users.alice.name"
  assert body["value"] == "Alice"
  assert is_integer(body["revision"])
end

test "GET /entries/:path returns 404 for missing", %{conn: conn, org: org, store: store} do
  conn = get(conn, ~p"/api/stores/#{org.slug}/#{store.name}/entries/no.such.path")
  assert %{"error" => "not_found"} = json_response(conn, 404)
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement** — add `show/2` to the controller:

```elixir
def show(conn, %{"path" => path_segments}) do
  path = Enum.join(path_segments, ".")
  store = conn.assigns.store_token.store

  case Sync.get_entry(store, path) do
    {:ok, entry} ->
      json(conn, %{
        "path" => entry.path,
        "value" => entry.value,
        "type" => entry.type,
        "revision" => entry.revision
      })

    {:error, :not_found} ->
      conn |> put_status(404) |> json(%{"error" => "not_found"})
  end
end
```

Add `Dust.Sync.get_entry/2`:

```elixir
def get_entry(store, path) do
  # Read a single entry from authoritative storage.
  # Return {:ok, %{path, value, type, revision}} | {:error, :not_found}
  # Mirror the read pattern used by other server-side single-entry reads.
end
```

**Step 4: Add route**

Phoenix routes with dots: use a wildcard.

```elixir
get "/stores/:org/:store/entries/*path", EntriesApiController, :show
```

This captures `users.alice.name` as `["users.alice.name"]` in params (Phoenix splits on `/`, not `.`, so the dots are preserved in a single segment — verify by running the test; if Phoenix splits on `.` too, the `Enum.join` in the controller handles it either way).

**Step 5:** Run — PASS. If the wildcard route conflicts with the `:index` route, order matters: put `:show` **after** `:index` in the router scope so `/entries` (no wildcard) matches `:index` first.

**Step 6: Commit**

```bash
git add server/lib/dust_web/controllers/api/entries_api_controller.ex \
        server/test/dust_web/controllers/api/entries_api_controller_test.exs \
        server/lib/dust/sync.ex \
        server/lib/dust_web/router.ex
git commit -m "feat(server): GET /api/stores/:org/:store/entries/*path single-entry read"
```

---

### Task 18: End-to-end verification via `mix precommit`

**Files:** none modified.

**Step 1:** From the server directory:

```bash
cd server && mix precommit
```

Expected: format clean, compile clean, all tests pass. Fix any issues surfaced.

**Step 2:** From the SDK directory:

```bash
cd sdk/elixir && mix test
```

Expected: all tests pass.

**Step 3: Commit any format fixes** (if any):

```bash
git commit -am "chore: mix format"
```

---

## Verification checklist

Before declaring Phase 1 done, verify each of these:

- [ ] `Dust.enum/2` still returns the flat `[{path, value}, ...]` list unchanged.
- [ ] `Dust.enum/3` returns `%Dust.Page{}` with `items` and `next_cursor`.
- [ ] `Dust.enum/3` supports `:limit`, `:after`, `:order`, `:select`.
- [ ] `select: :keys` returns paths only.
- [ ] `select: :prefixes` with pattern ending in `.**` or `**` returns unique next-segment prefixes.
- [ ] `select: :prefixes` with invalid pattern returns `{:error, :invalid_pattern_for_prefixes}`.
- [ ] `Dust.entry/2` returns `{:ok, %Dust.Entry{revision: integer}}` or `{:error, :not_found}`.
- [ ] Memory and Ecto adapters both support all the new browse options with passing tests.
- [ ] `GET /api/stores/:org/:store/entries` accepts `pattern`, `limit`, `after`, `order`, `select` query params.
- [ ] Response shape matches the spec in this plan.
- [ ] `GET /api/stores/:org/:store/entries/*path` returns a single entry with revision, or 404.
- [ ] All endpoints require a valid Bearer token (reject 401 without auth).
- [ ] `mix precommit` passes in `server/` and `mix test` passes in `sdk/elixir/`.
- [ ] No `try`/`rescue` anywhere (Task 14b takes the validate-up-front path).
- [ ] `mix format` is clean.

## Cross-SDK parity check (reminder)

The project has a hard guideline: **every read feature must be expressible as SQL against the local cache schema**. Verify that all of `enum/3` with `:keys`, `:prefixes`, and `:after` are translatable to SQL:

- `:keys` → `SELECT path FROM cache_entries WHERE ... ORDER BY path LIMIT N`
- `:prefixes` → `SELECT DISTINCT <prefix_expr> FROM cache_entries WHERE ... ORDER BY ... LIMIT N` (in Phase 1 we're doing the prefix extraction in Elixir, not SQL, but the shape is SQL-compatible — when we port to Ruby/Python SQLite we'll push the DISTINCT into SQL)
- `:after` → `WHERE path > ?` (asc) or `WHERE path < ?` (desc)
- `order` → `ORDER BY path ASC|DESC`

All check out. When Ruby/Python SDKs are built, the same schema shape will serve the same features without semantic changes.

## What Phase 2 picks up from here

- `range/4` will reuse the same `%Dust.Page{}` struct and the same `:after` cursor shape.
- `get_many/2` will reuse `read_entry/3` under the hood.
- Both will ship matching HTTP endpoints (`GET /api/stores/.../entries/range`, `POST /api/stores/.../entries/batch`).
