# Phase 4a — Crystal CLI Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Subagents implement + test + report; the main session commits. Strict TDD per task.

**Goal:** Bring the Dust Crystal CLI to parity with Phases 1-3 of the Elixir SDK by adding `entry`, paginated/projected `enum`, `range`, `get-many`, and `watch --include-current` — all served from the local SQLite cache (writes still go over WebSocket as today).

**Architecture:** Port the same SQL-backed read primitives we built for `Dust.Cache.Ecto` into the existing Crystal `Dust::Cache` (`cli/src/dust/cache/sqlite.cr`). Each new CLI command reads from the cache directly. No new HTTP client is added — the CLI stays WebSocket-only for writes and uses the local SQLite cache for all reads. This keeps cross-SDK parity with the Elixir Ecto adapter and matches the project guideline "reads expressible as SQL against the local cache."

**Tech stack:** Crystal 1.12+, sqlite3 shard, custom `phoenix_client` fork, built-in `JSON`/`spec`. No new dependencies.

**Design reference:** `docs/plans/2026-04-13-kv-native-features-design.md` — Phase 4 section.

---

## Background the engineer needs

### Current CLI structure

- Entry point: `cli/src/dust.cr` → `Dust::CLI.run(ARGV)`
- Command dispatch: simple `case` statement in `cli/src/dust/cli.cr:14-53`. No CLI framework — manual flag parsing per command.
- 13 commands under `cli/src/dust/commands/`. The relevant ones for this phase are `data.cr` (get, put, enum, merge, delete) and `watch.cr`.
- Local cache: `cli/src/dust/cache/sqlite.cr`. SQLite-backed, schema:
  ```sql
  CREATE TABLE IF NOT EXISTS dust_cache (
    store TEXT NOT NULL,
    path TEXT NOT NULL,
    value TEXT NOT NULL,
    type TEXT NOT NULL,
    seq INTEGER NOT NULL,
    PRIMARY KEY (store, path)
  )
  ```
  Plus a sentinel row at `path = "_dust:last_seq"` tracking the highest seq seen.
- Cache hydration: each command joins the store's Phoenix channel with `last_seq`, server sends catch-up events via `"event"` broadcasts, the CLI processes them via `on_event` and writes to cache, then sleeps 0.2s and reads. **The 0.2s sleep is a pre-existing race; this phase does NOT fix it.**
- Glob matching: `cli/src/dust/glob.cr` — separate from but presumably equivalent to the Elixir-side `Dust.Protocol.Glob` and the new `Dust.Glob`. Has its own `Glob.match?(path, pattern)` function.
- Output formatting: `cli/src/dust/output.cr` — `Output.json`, `Output.error`, `Output.success`. All data commands print pretty-printed JSON.
- Tests: `cli/spec/` using Crystal's built-in `spec`. Cache tests use in-memory SQLite (`:memory:`). Integration tests require a live server (gated on `DUST_TEST_TOKEN` env var).

### Schema parity check (project guideline)

The Crystal cache schema is **already byte-for-byte equivalent** to the Elixir Ecto schema in column names, types, and primary key. This phase MUST NOT diverge from that. If you're tempted to add a column or index, stop and either add it to both at once or document why it's only in one.

### Cross-SDK guideline alignment

- All new read features in this phase must be expressible as SQL against the cache table.
- The cache schema must remain identical to the Elixir Ecto schema.
- This is the same guideline that gated Phase 1 and Phase 2 — same rules apply here.

---

## Semantics pinned down

### `dust entry <store> <path>`

```bash
dust entry users/test users.alice.name
# {"path": "users.alice.name", "value": "Alice", "type": "string", "revision": 7}
```

- Returns the entry as JSON with `path`, `value`, `type`, `revision` (mapping `seq` → `revision` to match the HTTP API contract).
- Exits 0 on success.
- Exits non-zero with `{"error": "not_found"}` to stderr if the path is not in the cache.
- Calls `cache.read_entry(store, path)` which returns `{value, type, seq}` or `nil`.
- This is leaf-only; subtree assembly is deferred (consistent with the Elixir SDK).

### `dust enum <store> <pattern>` with new flags

Existing flagless behavior is preserved (returns `{path => value}` JSON object for backwards compatibility). New flags activate the paginated `Dust::Page`-equivalent JSON shape:

```bash
dust enum users/test 'users.**' --limit 50 --order desc --select keys
# {"items": ["users.bob.name", "users.alice.name"], "next_cursor": null}

dust enum users/test 'users.**' --select prefixes
# {"items": ["users.alice", "users.bob"], "next_cursor": null}
```

- Flags: `--limit N`, `--after CURSOR`, `--order asc|desc`, `--select entries|keys|prefixes`.
- Defaults: `limit=50`, `order=asc`, `select=entries`.
- `--select prefixes` requires the pattern to end in `.**` or be `**`. Otherwise stderr error + exit non-zero.
- Output shape: `{"items": [...], "next_cursor": "..." | null}`.
- For `select=entries`, items are `{"path", "value", "type", "revision"}` objects (rich, like the HTTP API).
- For `select=keys` or `select=prefixes`, items are plain strings.
- **Backwards compatibility:** if NO new flags are passed, fall back to the existing `read_all + glob filter` behavior and print `{path => value}` map. This avoids breaking existing CLI scripts.

### `dust range <store> <from> <to>`

```bash
dust range users/test users.a users.z --limit 100 --order asc
# {"items": [...], "next_cursor": null}
```

- New command. Both `from` (inclusive) and `to` (exclusive) are required.
- Flags: `--limit N`, `--after CURSOR`, `--order asc|desc`, `--select entries|keys`.
- `--select prefixes` is rejected (matches SDK semantics).
- `from >= to` returns `{"items": [], "next_cursor": null}` (no error).
- Same output shape as `enum` with flags.

### `dust get-many <store> <path>...`

```bash
dust get-many users/test users.alice.name users.bob.name users.no_such
# {"entries": {"users.alice.name": "Alice", "users.bob.name": "Bob"}, "missing": ["users.no_such"]}
```

- New command. Takes the store and one or more path arguments.
- Output shape: rich envelope with `entries` and `missing`, matching the HTTP API. Different from the SDK's flat `%{path => value}` map — the CLI follows the HTTP shape because it's more useful from a shell.
- Empty list of paths returns `{"entries": {}, "missing": []}`.
- Each entry value in the response is the materialized JSON value (no metadata wrapper).
- Maximum 1000 paths per call (matches HTTP API).

### `dust watch <store> <pattern>` with `--include-current`

```bash
dust watch users/test 'users.**' --include-current --limit 50
```

- New flag: `--include-current`. When set, the CLI:
  1. Reads matching entries from the local cache via `cache.browse(store, pattern, limit, order, select=entries)`.
  2. Emits each as a JSON line to stdout in the watch output format, BEFORE registering the on_event handler.
  3. Then proceeds with the normal watch flow (register handler, stream live events).
- Bootstrap event JSON shape: `{"op": "present", "path": ..., "value": ..., "type": ..., "seq": ...}`. The `op` field is `"present"` (synthetic, distinct from `set`/`delete`/`merge` so consumers can distinguish or filter).
- Honors `--limit` and `--order` flags during bootstrap.
- The race window in Crystal is different from Elixir (no GenServer single-thread guarantee), but the practical guarantee holds because:
  - Crystal CLI is single-fiber for command setup.
  - The bootstrap loop runs synchronously in `main` BEFORE `conn.on_event` registers the live handler.
  - Live events arriving on the WebSocket are buffered by the phoenix_client until a handler is registered.
- This is a CLI convenience feature, not a distributed-systems bootstrap protocol — same intent as the SDK version.

---

## Scope

**In scope:**

1. New `Dust::Cache` methods: `read_entry/2`, `read_many/2`, `browse/3` (with full options).
2. New CLI commands: `entry`, `range`, `get-many`.
3. Extended CLI commands: `enum` (new flags, new output shape), `watch` (new `--include-current` flag).
4. Unit tests for each new cache method using `:memory:` SQLite.
5. Optional: a small flag-parsing helper to avoid hand-rolling `--limit`/`--order`/`--select` parsing across multiple commands. Only if it makes the code cleaner.

**Out of scope:**

- Fixing the 0.2s `sleep` race (pre-existing, deferred).
- Any HTTP client integration. CLI stays WebSocket-only.
- Subtree assembly in `entry` (leaf-only, matches SDK).
- TypeScript SDK parity (Phase 4b).
- Integration tests against a real server. Cache tests are unit tests with `:memory:` SQLite. CLI command tests can be added as integration tests if useful, but are NOT required for this phase.
- New cache columns or schema changes. The schema must stay in lockstep with Elixir Ecto.

---

## Task list

### Task 1: `Dust::Cache#read_entry`

**Files:**
- Modify: `cli/src/dust/cache/sqlite.cr`
- Modify: `cli/spec/cache/sqlite_spec.cr`

**Step 1: Failing test**

```crystal
# cli/spec/cache/sqlite_spec.cr — add to existing describe block
describe "#read_entry" do
  it "returns {value, type, seq} for present entries" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a.b", JSON::Any.new("hello"), "string", 7_i64)

    result = cache.read_entry("store", "a.b")
    result.should_not be_nil
    result.not_nil![:value].should eq JSON::Any.new("hello")
    result.not_nil![:type].should eq "string"
    result.not_nil![:seq].should eq 7_i64
  end

  it "returns nil for missing entries" do
    cache = Dust::Cache.new(":memory:")
    cache.read_entry("store", "missing").should be_nil
  end
end
```

**Step 2: Run — FAIL.**

```bash
cd cli && crystal spec spec/cache/sqlite_spec.cr
```

Expected: undefined method `read_entry`.

**Step 3: Implement**

```crystal
# cli/src/dust/cache/sqlite.cr — add after existing #read method
def read_entry(store : String, path : String) : NamedTuple(value: JSON::Any, type: String, seq: Int64)?
  @db.query_one?(
    "SELECT value, type, seq FROM dust_cache WHERE store = ? AND path = ?",
    store, path,
    as: {String, String, Int64}
  ).try do |(value_json, type_str, seq)|
    {value: JSON.parse(value_json), type: type_str, seq: seq}
  end
end
```

Match the existing module's style (look at the existing `#read` method for the query pattern and naming conventions).

**Step 4:** Run — PASS.

**Step 5: Hand back to main session for commit.**

Commit message: `feat(cli): Cache#read_entry returns {value, type, seq}`

---

### Task 2: `Dust::Cache#read_many`

**Files:**
- Modify: `cli/src/dust/cache/sqlite.cr`
- Modify: `cli/spec/cache/sqlite_spec.cr`

**Step 1: Failing tests**

```crystal
describe "#read_many" do
  it "returns a hash of present entries" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a", JSON::Any.new(1_i64), "integer", 1_i64)
    cache.write("store", "b", JSON::Any.new(2_i64), "integer", 2_i64)

    result = cache.read_many("store", ["a", "b"])
    result.size.should eq 2
    result["a"][:value].should eq JSON::Any.new(1_i64)
    result["b"][:value].should eq JSON::Any.new(2_i64)
  end

  it "omits missing paths" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a", JSON::Any.new(1_i64), "integer", 1_i64)

    result = cache.read_many("store", ["a", "missing"])
    result.keys.should eq ["a"]
  end

  it "returns empty hash for empty paths list" do
    cache = Dust::Cache.new(":memory:")
    cache.read_many("store", [] of String).should be_empty
  end

  it "deduplicates input paths" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a", JSON::Any.new(1_i64), "integer", 1_i64)

    result = cache.read_many("store", ["a", "a", "a"])
    result.size.should eq 1
  end
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

```crystal
def read_many(store : String, paths : Array(String))
  unique = paths.uniq
  return {} of String => NamedTuple(value: JSON::Any, type: String, seq: Int64) if unique.empty?

  placeholders = Array.new(unique.size, "?").join(", ")
  args = [store] + unique
  sql = "SELECT path, value, type, seq FROM dust_cache WHERE store = ? AND path IN (#{placeholders})"

  result = {} of String => NamedTuple(value: JSON::Any, type: String, seq: Int64)
  @db.query(sql, args: args) do |rs|
    rs.each do
      path = rs.read(String)
      value_json = rs.read(String)
      type_str = rs.read(String)
      seq = rs.read(Int64)
      result[path] = {value: JSON.parse(value_json), type: type_str, seq: seq}
    end
  end
  result
end
```

**SECURITY NOTE:** Same as the Elixir server pattern — only the placeholder count is interpolated into SQL; values are bound positionally. Verify the Crystal sqlite3 shard supports passing an array via `args:` (look at how `#read` does it).

**Step 4:** Run — PASS.

**Step 5: Commit**

Message: `feat(cli): Cache#read_many returns hash of present entries`

---

### Task 3: `Dust::Cache#browse` with pattern + cursor + limit + order + select

**Files:**
- Modify: `cli/src/dust/cache/sqlite.cr`
- Modify: `cli/spec/cache/sqlite_spec.cr`

**Step 1: Failing tests**

This is the biggest cache method. Cover the cases that matter:

```crystal
describe "#browse" do
  it "returns entries matching pattern with default order asc and limit 50" do
    cache = Dust::Cache.new(":memory:")
    %w(a.1 a.2 a.3 b.1).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end

    items, cursor = cache.browse("store", pattern: "a.*", limit: 50)
    items.size.should eq 3
    items.map { |row| row[:path] }.should eq ["a.1", "a.2", "a.3"]
    cursor.should be_nil
  end

  it "honors limit and returns next_cursor" do
    cache = Dust::Cache.new(":memory:")
    %w(a b c d e).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end

    items, cursor = cache.browse("store", pattern: "**", limit: 2)
    items.map { |r| r[:path] }.should eq ["a", "b"]
    cursor.should eq "b"
  end

  it "resumes from cursor" do
    cache = Dust::Cache.new(":memory:")
    %w(a b c d e).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end

    items, _ = cache.browse("store", pattern: "**", limit: 2, after: "b")
    items.map { |r| r[:path] }.should eq ["c", "d"]
  end

  it "supports order: :desc" do
    cache = Dust::Cache.new(":memory:")
    %w(a b c).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end

    items, _ = cache.browse("store", pattern: "**", limit: 10, order: "desc")
    items.map { |r| r[:path] }.should eq ["c", "b", "a"]
  end

  it "supports select: keys" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "a", JSON::Any.new("x"), "string", 1_i64)
    cache.write("store", "b", JSON::Any.new("y"), "string", 2_i64)

    items, _ = cache.browse("store", pattern: "**", limit: 10, select: "keys")
    items.should eq ["a", "b"]
  end

  it "supports select: prefixes for ** pattern" do
    cache = Dust::Cache.new(":memory:")
    %w(users.alice.name users.bob.name posts.hi).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end

    items, _ = cache.browse("store", pattern: "**", limit: 10, select: "prefixes")
    items.should eq ["posts", "users"]
  end

  it "supports select: prefixes for users.** pattern" do
    cache = Dust::Cache.new(":memory:")
    %w(users.alice.name users.alice.email users.bob.name).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end

    items, _ = cache.browse("store", pattern: "users.**", limit: 10, select: "prefixes")
    items.should eq ["users.alice", "users.bob"]
  end

  it "rejects select: prefixes with invalid pattern" do
    cache = Dust::Cache.new(":memory:")

    expect_raises(ArgumentError, /prefixes/) do
      cache.browse("store", pattern: "a.*.b", limit: 10, select: "prefixes")
    end
  end
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

The implementation follows the same shape as the Elixir Ecto cache: build SQL with parameterized cursor + LIKE prefix + order, post-filter by glob in Crystal, project to entries/keys/prefixes.

```crystal
def browse(
  store : String,
  pattern : String = "**",
  limit : Int32 = 50,
  after : String? = nil,
  order : String = "asc",
  select : String = "entries"
) : Tuple(Array, String?)
  validate_select_pattern!(select, pattern)

  literal_prefix = literal_prefix_of(pattern)
  rows = fetch_rows(store, literal_prefix, after, order, limit + 1)

  matched = rows.select { |row| Glob.match?(row[:path], pattern) }
  page = matched.first(limit)

  next_cursor =
    if matched.size > limit && !page.empty?
      page.last[:path]
    else
      nil
    end

  projected = project_page(page, select, pattern)
  {projected, next_cursor}
end

private def fetch_rows(store, literal_prefix, after, order, limit)
  where_clauses = ["store = ?"]
  args = [store] of (String | Int32)

  if literal_prefix && !literal_prefix.empty?
    where_clauses << "path LIKE ? ESCAPE '\\'"
    args << escape_like(literal_prefix) + "%"
  end

  if after
    where_clauses << (order == "asc" ? "path > ?" : "path < ?")
    args << after
  end

  where_clauses << "path != '_dust:last_seq'"

  sql = "SELECT path, value, type, seq FROM dust_cache WHERE #{where_clauses.join(" AND ")} ORDER BY path #{order.upcase} LIMIT ?"
  args << limit

  rows = [] of NamedTuple(path: String, value: JSON::Any, type: String, seq: Int64)
  @db.query(sql, args: args) do |rs|
    rs.each do
      rows << {
        path: rs.read(String),
        value: JSON.parse(rs.read(String)),
        type: rs.read(String),
        seq: rs.read(Int64),
      }
    end
  end
  rows
end

private def literal_prefix_of(pattern : String) : String?
  return "" if pattern == "**"
  segments = pattern.split('.')
  literal = [] of String
  segments.each do |seg|
    break if seg.includes?('*')
    literal << seg
  end
  literal.empty? ? nil : literal.join('.')
end

private def escape_like(s : String) : String
  s.gsub("\\", "\\\\").gsub("%", "\\%").gsub("_", "\\_")
end

private def validate_select_pattern!(select : String, pattern : String)
  if select == "prefixes" && pattern != "**" && !pattern.ends_with?(".**")
    raise ArgumentError.new("select: prefixes requires pattern ending in .** or being ** (got #{pattern})")
  end
end

private def project_page(page, select, pattern)
  case select
  when "entries"
    page
  when "keys"
    page.map { |row| row[:path] }
  when "prefixes"
    prefixes_of(page, pattern)
  else
    raise ArgumentError.new("invalid select: #{select}")
  end
end

private def prefixes_of(page, pattern)
  literal = literal_prefix_of_for_prefixes(pattern)
  page.map { |row| extract_prefix(row[:path], literal) }
      .compact
      .uniq
      .sort
end

private def literal_prefix_of_for_prefixes(pattern : String) : String
  return "" if pattern == "**"
  pattern.sub(/\.\*\*$/, "")
end

private def extract_prefix(path : String, literal : String) : String?
  if literal.empty?
    segments = path.split('.', 2)
    segments.first?
  else
    prefix_dot = literal + "."
    return nil unless path.starts_with?(prefix_dot)
    rest = path[prefix_dot.size..]
    next_seg = rest.split('.', 2).first
    "#{literal}.#{next_seg}"
  end
end
```

This is a chunk of code. Use the existing `cli/src/dust/glob.cr` for `Glob.match?` — verify its signature first; it might be `Glob.match?(path, pattern)` or `Glob.match?(pattern, path)`.

**KNOWN LIMITATION (matches Phase 1 C1 fix):** The current implementation fetches `limit + 1` raw rows and post-filters by glob. If the glob is narrower than the LIKE prefix (e.g., pattern `a.*.b` with literal prefix `a`), pagination can drop matches past the raw window. **For Phase 4a we accept this limitation**, document it in a code comment, and defer the chunked-walk fix to a follow-up. This matches the Elixir Ecto adapter's state BEFORE the C1 fix and is acceptable for an MVP CLI. Add a TODO comment in the `fetch_rows` method.

If you want to be more thorough, you can port the chunked-walk loop now. But it's a significant amount of code and not critical for CLI MVP usability.

**Step 4:** Run — PASS.

**Step 5: Commit**

Message: `feat(cli): Cache#browse with pattern, cursor, limit, order, select`

---

### Task 4: `Dust::Cache#browse` range support (`from`/`to`)

**Files:**
- Modify: `cli/src/dust/cache/sqlite.cr`
- Modify: `cli/spec/cache/sqlite_spec.cr`

**Step 1: Failing tests**

```crystal
describe "#browse with from/to range" do
  it "returns entries in [from, to)" do
    cache = Dust::Cache.new(":memory:")
    %w(a b c d e).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end

    items, _ = cache.browse("store", from: "b", to: "d", limit: 10)
    items.map { |r| r[:path] }.should eq ["b", "c"]
  end

  it "from is inclusive, to is exclusive" do
    # mirror Phase 2 Memory test
  end

  it "from >= to returns empty" do
    cache = Dust::Cache.new(":memory:")
    cache.write("store", "x", JSON::Any.new("x"), "string", 1_i64)
    items, _ = cache.browse("store", from: "z", to: "a", limit: 10)
    items.should be_empty
  end

  it "range with limit + cursor paginates" do
    cache = Dust::Cache.new(":memory:")
    %w(a b c d e).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end
    items, cursor = cache.browse("store", from: "a", to: "z", limit: 2)
    items.map { |r| r[:path] }.should eq ["a", "b"]
    cursor.should eq "b"
  end

  it "range with order :desc" do
    cache = Dust::Cache.new(":memory:")
    %w(a b c d).each_with_index do |p, i|
      cache.write("store", p, JSON::Any.new(p), "string", (i + 1).to_i64)
    end
    items, _ = cache.browse("store", from: "a", to: "d", limit: 10, order: "desc")
    items.map { |r| r[:path] }.should eq ["c", "b", "a"]
  end

  it "range rejects select: prefixes" do
    cache = Dust::Cache.new(":memory:")
    expect_raises(ArgumentError) do
      cache.browse("store", from: "a", to: "z", select: "prefixes")
    end
  end
end
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

Extend `browse` to accept `from:` and `to:` keyword args (default `nil`). When BOTH are set, branch into a range path that bypasses the LIKE filter and the glob post-filter entirely:

```crystal
def browse(
  store : String,
  pattern : String = "**",
  limit : Int32 = 50,
  after : String? = nil,
  order : String = "asc",
  select : String = "entries",
  from : String? = nil,
  to : String? = nil
)
  if from && to
    # Range mode — reject :prefixes, no glob post-filter needed
    raise ArgumentError.new("select: prefixes not supported for range") if select == "prefixes"
    rows = fetch_range_rows(store, from, to, after, order, limit + 1)
    page = rows.first(limit)
    next_cursor =
      if rows.size > limit && !page.empty?
        page.last[:path]
      else
        nil
      end
    projected = project_page(page, select, pattern)
    return {projected, next_cursor}
  end

  # Existing pattern path...
end

private def fetch_range_rows(store, from, to, after, order, limit)
  where_clauses = ["store = ?", "path >= ?", "path < ?"]
  args = [store, from, to] of (String | Int32)

  if after
    where_clauses << (order == "asc" ? "path > ?" : "path < ?")
    args << after
  end

  where_clauses << "path != '_dust:last_seq'"

  sql = "SELECT path, value, type, seq FROM dust_cache WHERE #{where_clauses.join(" AND ")} ORDER BY path #{order.upcase} LIMIT ?"
  args << limit

  # ... same row collection as fetch_rows ...
end
```

**Step 4:** Run — PASS.

**Step 5: Commit**

Message: `feat(cli): Cache#browse supports from/to range filter`

---

### Task 5: `dust entry` command

**Files:**
- Modify: `cli/src/dust/commands/data.cr` (add `entry` static method) — OR create a new file if `data.cr` is getting unwieldy
- Modify: `cli/src/dust/cli.cr` (route `entry` command to `Commands::Data.entry`)
- Add: `cli/spec/commands/entry_spec.cr` (only if you can structure it as a unit test against a mock cache; otherwise skip and rely on smoke testing)

**Step 1: Implementation sketch**

```crystal
# cli/src/dust/commands/data.cr — add static method
def self.entry(config, args)
  if args.size < 2
    Output.error("usage: dust entry <store> <path>")
    return
  end

  store_name = args[0]
  path = args[1]

  cache = Cache.new(config.cache_path)
  ensure_synced(config, cache, store_name)  # join channel, sleep 0.2, etc. — reuse existing helper

  result = cache.read_entry(store_name, path)

  if result.nil?
    STDERR.puts %({"error": "not_found"})
    exit 1
  end

  Output.json({
    "path"     => path,
    "value"    => result[:value],
    "type"     => result[:type],
    "revision" => result[:seq],
  })
end
```

**Step 2: Routing**

In `cli/src/dust/cli.cr`'s case statement, add:

```crystal
when "entry"
  Commands::Data.entry(config, rest)
```

**Step 3: Run a manual smoke test**

```bash
cd cli && shards build
./bin/dust entry test/store users.alice
```

**Step 4: Commit**

Message: `feat(cli): dust entry command returns entry with revision`

---

### Task 6: `dust enum` with `--limit`/`--after`/`--order`/`--select`

**Files:**
- Modify: `cli/src/dust/commands/data.cr`
- Modify: `cli/spec/...` (optional)

**Step 1: Implementation**

Inside `Commands::Data.enum`, parse the new flags BEFORE the existing flagless behavior. If any of the new flags are present, route to the paginated path; otherwise preserve the existing `read_all + glob filter + {path => value}` output.

```crystal
def self.enum(config, args)
  store_name = args.shift?
  pattern = args.shift?
  Output.error("usage: dust enum <store> <pattern> [--limit N] [--after C] [--order asc|desc] [--select entries|keys|prefixes]") unless store_name && pattern

  flags = parse_flags(args)
  cache = Cache.new(config.cache_path)
  ensure_synced(config, cache, store_name)

  if flags.empty?
    # Existing flagless behavior
    entries = cache.read_all(store_name)
                   .select { |entry| Glob.match?(entry[:path], pattern) }
                   .each_with_object({} of String => JSON::Any) { |entry, acc| acc[entry[:path]] = entry[:value] }
    Output.json(entries)
  else
    # New paginated path
    limit = (flags["limit"]? || "50").to_i
    after = flags["after"]?
    order = flags["order"]? || "asc"
    select = flags["select"]? || "entries"

    items, next_cursor =
      begin
        cache.browse(store_name, pattern: pattern, limit: limit, after: after, order: order, select: select)
      rescue ex : ArgumentError
        Output.error(ex.message)
        return
      end

    Output.json({
      "items"       => render_items(items, select),
      "next_cursor" => next_cursor,
    })
  end
end

private def self.render_items(items, select)
  case select
  when "keys", "prefixes"
    items  # already strings
  else
    items.map do |row|
      {
        "path"     => row[:path],
        "value"    => row[:value],
        "type"     => row[:type],
        "revision" => row[:seq],
      }
    end
  end
end

private def self.parse_flags(args : Array(String)) : Hash(String, String)
  flags = {} of String => String
  i = 0
  while i < args.size
    arg = args[i]
    if arg.starts_with?("--")
      name = arg[2..]
      i += 1
      Output.error("missing value for --#{name}") if i >= args.size
      flags[name] = args[i]
    end
    i += 1
  end
  flags
end
```

**Step 2:** Manual smoke test against existing data.

**Step 3: Commit**

Message: `feat(cli): dust enum supports --limit, --after, --order, --select`

---

### Task 7: `dust range` command

**Files:**
- Modify: `cli/src/dust/commands/data.cr`
- Modify: `cli/src/dust/cli.cr` (route `range`)

**Step 1: Implementation**

```crystal
def self.range(config, args)
  store_name = args.shift?
  from = args.shift?
  to = args.shift?

  unless store_name && from && to
    Output.error("usage: dust range <store> <from> <to> [--limit N] [--after C] [--order asc|desc] [--select entries|keys]")
    return
  end

  flags = parse_flags(args)
  limit = (flags["limit"]? || "50").to_i
  after = flags["after"]?
  order = flags["order"]? || "asc"
  select = flags["select"]? || "entries"

  cache = Cache.new(config.cache_path)
  ensure_synced(config, cache, store_name)

  items, next_cursor =
    begin
      cache.browse(store_name, from: from, to: to, limit: limit, after: after, order: order, select: select)
    rescue ex : ArgumentError
      Output.error(ex.message)
      return
    end

  Output.json({
    "items"       => render_items(items, select),
    "next_cursor" => next_cursor,
  })
end
```

Add routing in `cli.cr`:

```crystal
when "range"
  Commands::Data.range(config, rest)
```

**Step 2: Smoke test, commit.**

Message: `feat(cli): dust range command for lexicographic range reads`

---

### Task 8: `dust get-many` command

**Files:**
- Modify: `cli/src/dust/commands/data.cr`
- Modify: `cli/src/dust/cli.cr`

**Step 1: Implementation**

```crystal
def self.get_many(config, args)
  store_name = args.shift?
  unless store_name && !args.empty?
    Output.error("usage: dust get-many <store> <path> [<path>...]")
    return
  end

  paths = args
  if paths.size > 1000
    Output.error("maximum 1000 paths per call")
    return
  end

  cache = Cache.new(config.cache_path)
  ensure_synced(config, cache, store_name)

  result = cache.read_many(store_name, paths)

  found = result.transform_values { |v| v[:value] }
  missing = paths.uniq - found.keys

  Output.json({
    "entries" => found,
    "missing" => missing,
  })
end
```

Routing in `cli.cr`:

```crystal
when "get-many"
  Commands::Data.get_many(config, rest)
```

Note: `get-many` with a hyphen is the CLI convention; in Crystal the method is `get_many` (snake_case). Map them in the case statement.

**Step 2:** Smoke test, commit.

Message: `feat(cli): dust get-many command for batch reads`

---

### Task 9: `dust watch --include-current`

**Files:**
- Modify: `cli/src/dust/commands/watch.cr`

**Step 1: Implementation**

In the existing watch command, look for the flag parsing block and add `--include-current` (boolean flag, no value) and `--limit` / `--order` (which are passed through to the cache.browse call during bootstrap).

```crystal
# Parse flags including new --include-current
include_current = false
limit = 50
order = "asc"

# ... existing flag parsing loop ...
case arg
when "--op"
  # existing
when "--include-current"
  include_current = true
when "--limit"
  limit = args[i + 1].to_i
  i += 1
when "--order"
  order = args[i + 1]
  i += 1
end

# ... existing channel join ...

# After channel join, BEFORE on_event handler is registered:
if include_current
  cache = Cache.new(config.cache_path)
  items, _ = cache.browse(store_name, pattern: pattern, limit: limit, order: order, select: "entries")

  items.each do |row|
    event = {
      "op"    => "present",
      "path"  => row[:path],
      "value" => row[:value],
      "type"  => row[:type],
      "seq"   => row[:seq],
    }
    puts event.to_json
  end
end

# Now register the live event handler — anything past this point is live, not bootstrap
conn.on_event do |event|
  # existing live event handling
end
```

The race-free guarantee in Crystal isn't as airtight as the Elixir GenServer model, but the practical guarantee is: while the bootstrap loop is running synchronously, no `on_event` handler is registered yet, so live events are buffered by `phoenix_client` and only start being processed after `conn.on_event` is called. As long as the bootstrap loop is genuinely synchronous (no `spawn`, no fiber yield), this works.

**Verify:** Look at what `phoenix_client` does between `join` and `on_event`. If it auto-processes events into nowhere (e.g., drops them on the floor without a handler), the design changes — flag this and STOP for guidance.

**Step 2:** Smoke test.

**Step 3: Commit**

Message: `feat(cli): dust watch supports --include-current`

---

### Task 10: End-to-end verification

**Files:** none modified.

**Step 1:** Run all CLI specs:
```bash
cd cli && crystal spec
```
Expected: green. Counts depend on existing test count + new cache method tests.

**Step 2:** Run a build:
```bash
cd cli && shards build
```
Expected: clean compile, no warnings about Crystal version, no missing methods.

**Step 3:** If a test server is available locally, do a manual smoke test of each new command. Otherwise note it as pending.

**Step 4: No commit needed.**

---

## Verification checklist

- [ ] `Dust::Cache#read_entry` returns `{value, type, seq}` or nil.
- [ ] `Dust::Cache#read_many` returns hash of present entries, dedupes input, omits missing.
- [ ] `Dust::Cache#browse` supports pattern + limit + after + order + select on the existing schema.
- [ ] `Dust::Cache#browse` supports `from`/`to` range mode (mutually exclusive with pattern in practice).
- [ ] `select: prefixes` rejects invalid patterns at the cache layer.
- [ ] `dust entry <store> <path>` returns entry JSON with revision, 404-style error if missing.
- [ ] `dust enum` with no flags preserves existing output shape (backwards compat).
- [ ] `dust enum` with new flags returns paginated `{items, next_cursor}` shape.
- [ ] `dust range` returns paginated range entries.
- [ ] `dust get-many` returns `{entries, missing}` envelope.
- [ ] `dust watch --include-current` emits cached entries as `{"op": "present", ...}` events before live events.
- [ ] All new Crystal cache methods have unit tests using `:memory:` SQLite.
- [ ] `crystal spec` is green.
- [ ] `shards build` succeeds.
- [ ] No new dependencies added to `shard.yml`.
- [ ] Cache schema is unchanged (no new columns, no new indexes).

## Cross-SDK parity check

- All new read commands route through `Dust::Cache#browse`/`#read_entry`/`#read_many`, which are pure SQL against the same `dust_cache` table.
- Schema is identical to Elixir Ecto cache.
- No new HTTP transport, no new dependencies.

When a Ruby/Python SDK is built, it will use the same SQL patterns against an identical schema. Phase 4a doesn't add to that surface; it just gives the CLI the same local-first reads the Elixir SDK has.

## Process reminder

Subagents implement + test + report. The main session commits.
