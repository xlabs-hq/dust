# Phase 4b — TypeScript SDK Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Subagents implement + test + report; the main session commits. Strict TDD per task.

**Goal:** Bring the Dust TypeScript SDK to parity with Phases 1-3 of the Elixir SDK by adding paginated `enum`, metadata-bearing `entry`, `range`, `getMany`, and race-free `watch` (bootstrap watch) — all served from the existing in-memory cache. The SDK stays WebSocket-only; no HTTP client is added.

**Architecture:** Extend the existing `Cache` interface with `readEntry`, `readMany`, and a unified `browse` method that accepts either `pattern` or `from`/`to` range bounds plus `limit`/`after`/`order`/`select`. Port the same projection logic we built for Elixir Ecto and Crystal SQLite, but as JS `Map` walks instead of SQL. For bootstrap watch, add a new async `watch()` method (sync `on()` stays as-is) that awaits catch-up, snapshots the cache, and dispatches synchronously — leveraging JavaScript's single-threaded event loop for race-free ordering between bootstrap and live events, with a pending-events buffer in the subscription for events that arrive during the async hydration window.

**Tech stack:** TypeScript 5+, Vitest, WebSocket via Phoenix protocol, `msgpackr` for MessagePack, in-memory `Map`-backed cache. No new dependencies.

**Design reference:** `docs/plans/2026-04-13-kv-native-features-design.md` — Phase 4 section.

---

## Background the engineer needs

### Current shape (from Phase 4b recon)

**Public API (`sdk/typescript/src/dust.ts`):**
- `get(store, path): Promise<unknown>` — raw value
- `put`, `merge`, `delete`, `increment`, `add`, `remove` — writes
- `enum(store, pattern): Promise<Entry[]>` — flat, no pagination
- `on(store, pattern, callback): () => void` — sync subscription, no bootstrap
- `status(store): Status`
- `close(): void`

**Entry type (`src/types.ts:8-13`):**
```typescript
interface Entry {
  path: string
  value: unknown
  type: string
  seq: number
}
```
Already metadata-bearing. **Do NOT rename `seq` to `revision`** — the TS type stays `seq` for internal consistency. The public docstring can mention "sometimes called revision in other SDKs." Keeping the rename out of Phase 4b avoids breaking existing consumers.

**Cache (`src/cache.ts`):**
- Interface `Cache` has `get`, `set`, `delete`, `deletePrefix`, `entries(store, pattern)`, `lastSeq`, `setLastSeq`, `clear`.
- Only implementation: `MemoryCache` backed by `Map<string, Map<string, Entry>>`.
- `entries(store, pattern)` already walks the store's map, filters by glob, sorts ascending. No pagination, no projections, no range.

**Glob (`src/glob.ts`):**
- Same `**`/`*` dot-delimited algorithm as Elixir/Crystal.
- `match(pattern, path): boolean` — `match` is the export name.

**Tests (`sdk/typescript/test/`):**
- Vitest. ~75 tests across `glob.test.ts`, `cache.test.ts`, `dust.test.ts`, `codec.test.ts`, `connection.test.ts`, `integration.test.ts`.
- `cache.test.ts` uses `MemoryCache` directly with Vitest's `describe`/`it`/`expect`. Mirror that pattern for new cache tests.
- `dust.test.ts` uses a mock Connection and `Dust` class to verify event routing. Harder to mirror — check the existing subscription tests before writing new ones.

**Connection (`src/connection.ts`):**
- WebSocket + Phoenix protocol.
- `ensureJoined(store): Promise<void>` — idempotent join. Awaiting this guarantees the server has sent the initial snapshot.
- Dust class listens for server events via `conn.onEvent((topic, event) => this.handleEvent(...))`.

### The bootstrap watch race (the one hard thing)

Unlike Elixir (which uses single-threaded GenServer semantics) or Crystal (which uses mutex+queue), TS has JavaScript's single-threaded event loop. The guarantee is:

- Between `await X` and the next statement, **no userland code runs** (microtask boundary only).
- WebSocket `onmessage` events are macrotasks — they run **between** microtask queues, not inside them.
- Any synchronous block (no `await`) is atomic with respect to incoming WS messages.

This gives us a cheap ordering trick: **`watch()` can `await ensureJoined()`, then synchronously loop over cache entries and call the callback for each one — no live event can interleave mid-loop.** But events that arrive *during* the `await ensureJoined()` gap can still fire into the handler, so we need a pending buffer on the subscription to catch them and drain after bootstrap.

### Testing conventions

- Strict TDD per task.
- Use `@vitest/config` as-is; no new tools.
- Run `pnpm test` or `npm test` — whichever the repo uses (check `package.json` scripts).
- Type-check with `tsc --noEmit` — add to the test step if it isn't already there.

---

## Semantics pinned down

### `Dust.entry(store, path)` — metadata-bearing read

```typescript
async entry(store: string, path: string): Promise<Entry | null>
```

- Returns the cached `Entry` (with `seq`, `type`, `value`) or `null` if missing.
- Leaf-only. Subtree assembly is deferred (same as Elixir Phase 1 decision).
- Calls new `cache.readEntry(store, path)`.

### `Dust.enum(store, pattern)` — keep the current signature, add an overload

```typescript
// Existing, unchanged:
async enum(store: string, pattern: string): Promise<Entry[]>

// NEW overload:
async enum(store: string, pattern: string, opts: EnumOptions): Promise<Page<Entry | string>>
```

Where:
```typescript
interface EnumOptions {
  limit?: number;    // default 50, max 1000
  after?: string;    // opaque cursor
  order?: 'asc' | 'desc';  // default 'asc'
  select?: 'entries' | 'keys' | 'prefixes';  // default 'entries'
}

interface Page<T> {
  items: T[];
  nextCursor: string | null;
}
```

Use TypeScript function overloads so callers without opts get `Entry[]` (legacy) and callers with opts get `Page<Entry>` or `Page<string>` depending on `select`.

- Flagless call preserves the existing array shape — no breaking change.
- With opts, returns a `Page`.
- `select: 'prefixes'` requires pattern ending in `.**` or exactly `**`; otherwise throws `Error("select: prefixes requires pattern ending in .** or **")`.

### `Dust.range(store, from, to, opts?)` — new

```typescript
async range(
  store: string,
  from: string,
  to: string,
  opts?: RangeOptions
): Promise<Page<Entry | string>>
```

- `from` inclusive, `to` exclusive.
- Options: `limit`, `after`, `order`, `select: 'entries' | 'keys'` (no `'prefixes'`).
- `from >= to` returns `{ items: [], nextCursor: null }`.
- Calls `cache.browse({ from, to, ... })`.

### `Dust.getMany(store, paths)` — new

```typescript
async getMany(store: string, paths: string[]): Promise<Record<string, unknown>>
```

- Returns a plain object `{ [path]: value }`.
- Missing paths omitted.
- Dedupes input.
- Empty input returns `{}`.
- Max 1000 paths per call — throws `Error("getMany: maximum 1000 paths per call")` otherwise.

### `Dust.watch(store, pattern, callback, opts?)` — new async subscription

```typescript
type WatchEvent = Event | PresentEvent;

interface PresentEvent {
  op: 'present';
  path: string;
  value: unknown;
  type: string;
  seq: number;
}

async watch(
  store: string,
  pattern: string,
  callback: (event: WatchEvent) => void,
  opts?: { limit?: number; order?: 'asc' | 'desc' }
): Promise<() => void>
```

- Returns a Promise that resolves to an unsubscribe function.
- By the time the Promise resolves, all current matching entries have been dispatched to the callback as `{ op: 'present', ... }` events.
- Future events dispatched in-order after the Promise resolves.
- Events that arrive on the WS during bootstrap hydration are buffered per-subscription and drained after the present events are dispatched (order preserved).
- `opts.limit` caps bootstrap entries (default 50, max 1000). `opts.order` controls bootstrap dispatch order.
- `on()` is unchanged — callers who don't want bootstrap keep using it.

**Implementation sketch:**

```typescript
async watch(store, pattern, callback, opts = {}) {
  const limit = Math.min(opts.limit ?? 50, 1000);
  const order = opts.order ?? 'asc';

  // Register subscription with a pending buffer
  const sub: Subscription = {
    pattern,
    callback,
    bootstrapPending: true,
    pendingEvents: [],
  };
  this.subscriptionsFor(store).add(sub);
  const unsubscribe = () => this.subscriptionsFor(store).delete(sub);

  try {
    // Await catch-up — by the time this returns, the snapshot has been processed
    await this.ensureJoined(store);

    // Snapshot current matching entries
    const page = await this.cache.browse(store, {
      pattern,
      limit,
      order,
      select: 'entries',
    });

    // Dispatch bootstrap events SYNCHRONOUSLY (no await in loop).
    // JS single-thread guarantees no live event can interleave.
    for (const entry of page.items as Entry[]) {
      callback({
        op: 'present',
        path: entry.path,
        value: entry.value,
        type: entry.type,
        seq: entry.seq,
      });
    }

    // Drain any live events that arrived during the hydration gap
    for (const event of sub.pendingEvents) {
      callback(event);
    }
    sub.pendingEvents = [];
    sub.bootstrapPending = false;
  } catch (err) {
    unsubscribe();
    throw err;
  }

  return unsubscribe;
}
```

And `handleEvent` dispatches pending events to the buffer instead of the callback while `bootstrapPending` is true:

```typescript
// Inside existing handleEvent or similar:
for (const sub of this.subscriptionsFor(store)) {
  if (match(sub.pattern, path)) {
    if (sub.bootstrapPending) {
      sub.pendingEvents.push(event);
    } else {
      sub.callback(event);
    }
  }
}
```

---

## Scope

**In scope:**

1. `Page<T>` type
2. `Cache` interface extended with `readEntry`, `readMany`, `browse` callbacks
3. `MemoryCache` implementations for all three
4. `Dust.entry()` — new method
5. `Dust.enum()` — new overload with `EnumOptions`, `Page<T>` return
6. `Dust.range()` — new method
7. `Dust.getMany()` — new method
8. `Dust.watch()` — new async method with bootstrap
9. New `Subscription` internal type with `bootstrapPending` + `pendingEvents`
10. Update existing `handleEvent` subscription dispatch to respect `bootstrapPending`
11. Tests for every new thing

**Out of scope:**

- Renaming `seq` to `revision` in the public type (deliberate — keeps diff minimal)
- HTTP transport
- IndexedDB/localStorage cache persistence
- Reconnect/resync behavior improvements (pre-existing issue)
- Device ID persistence (pre-existing TODO)
- Subtree assembly in `entry()` (leaf-only, matches all other SDKs)
- Phase 5 (CAS / if_match) — that's its own phase

---

## Task list

### Task 1: `Page<T>` type

**Files:**
- Modify: `sdk/typescript/src/types.ts`
- Modify: `sdk/typescript/test/types.test.ts` (create if it doesn't exist — but types are tested implicitly elsewhere, so prefer to test via the first real consumer)

**Step 1: Add the type**

```typescript
// sdk/typescript/src/types.ts
export interface Page<T> {
  items: T[];
  nextCursor: string | null;
}
```

No test file is needed for a pure type declaration; type-checking via `tsc` is the test. If Vitest's config runs `tsc --noEmit` as part of the test step, that's sufficient. Otherwise add it to `package.json` scripts or rely on the first consumer test to catch type errors.

**Step 2: Run type check**

```bash
cd sdk/typescript && npx tsc --noEmit
```

Expected: clean, no errors.

**Step 3: Hand back for commit.**

Message: `feat(sdk-ts): add Page<T> type`

---

### Task 2: `Cache.readEntry` interface + `MemoryCache.readEntry` impl

**Files:**
- Modify: `sdk/typescript/src/cache.ts`
- Modify: `sdk/typescript/test/cache.test.ts`

**Step 1: Failing test**

```typescript
// test/cache.test.ts
describe('readEntry', () => {
  it('returns the entry for a present key', () => {
    const cache = new MemoryCache();
    const entry: Entry = { path: 'a.b', value: 'hello', type: 'string', seq: 7 };
    cache.set('store', 'a.b', entry);
    expect(cache.readEntry('store', 'a.b')).toEqual(entry);
  });

  it('returns null for a missing key', () => {
    const cache = new MemoryCache();
    expect(cache.readEntry('store', 'missing')).toBeNull();
  });

  it('returns null for a missing store', () => {
    const cache = new MemoryCache();
    expect(cache.readEntry('nope', 'any')).toBeNull();
  });
});
```

**Step 2: Run — FAIL**

```bash
cd sdk/typescript && npm test -- cache.test.ts
```

Expected: `MemoryCache.readEntry is not a function`.

**Step 3: Implement**

In `cache.ts`, add to the `Cache` interface:
```typescript
readEntry(store: string, path: string): Entry | null;
```

In `MemoryCache`:
```typescript
readEntry(store: string, path: string): Entry | null {
  return this.stores.get(store)?.get(path) ?? null;
}
```

(`this.stores` is the existing `Map<string, Map<string, Entry>>`. Match the existing naming — it may actually be called `data` or similar.)

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Cache.readEntry returns entry or null`

---

### Task 3: `Cache.readMany` interface + `MemoryCache.readMany` impl

**Files:**
- Modify: `sdk/typescript/src/cache.ts`
- Modify: `sdk/typescript/test/cache.test.ts`

**Step 1: Failing tests**

```typescript
describe('readMany', () => {
  it('returns a record of present entries', () => {
    const cache = new MemoryCache();
    const a: Entry = { path: 'a', value: 1, type: 'integer', seq: 1 };
    const b: Entry = { path: 'b', value: 2, type: 'integer', seq: 2 };
    cache.set('store', 'a', a);
    cache.set('store', 'b', b);
    const result = cache.readMany('store', ['a', 'b']);
    expect(result).toEqual({ a, b });
  });

  it('omits missing paths', () => {
    const cache = new MemoryCache();
    cache.set('store', 'a', { path: 'a', value: 1, type: 'integer', seq: 1 });
    expect(cache.readMany('store', ['a', 'missing'])).toEqual({
      a: { path: 'a', value: 1, type: 'integer', seq: 1 },
    });
  });

  it('returns empty for empty paths list', () => {
    const cache = new MemoryCache();
    expect(cache.readMany('store', [])).toEqual({});
  });

  it('deduplicates input paths', () => {
    const cache = new MemoryCache();
    const a: Entry = { path: 'a', value: 1, type: 'integer', seq: 1 };
    cache.set('store', 'a', a);
    expect(cache.readMany('store', ['a', 'a', 'a'])).toEqual({ a });
  });
});
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

Interface:
```typescript
readMany(store: string, paths: string[]): Record<string, Entry>;
```

Impl:
```typescript
readMany(store: string, paths: string[]): Record<string, Entry> {
  const storeMap = this.stores.get(store);
  if (!storeMap) return {};

  const result: Record<string, Entry> = {};
  const seen = new Set<string>();
  for (const path of paths) {
    if (seen.has(path)) continue;
    seen.add(path);
    const entry = storeMap.get(path);
    if (entry !== undefined) {
      result[path] = entry;
    }
  }
  return result;
}
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Cache.readMany returns record of present entries`

---

### Task 4: `Cache.browse` — interface + `MemoryCache` impl with pattern + limit + after + order + select

**Files:**
- Modify: `sdk/typescript/src/cache.ts`
- Modify: `sdk/typescript/test/cache.test.ts`

**Step 1: Failing tests**

```typescript
describe('browse', () => {
  const setup = () => {
    const cache = new MemoryCache();
    for (const [p, v] of [['a.1', 1], ['a.2', 2], ['a.3', 3], ['b.1', 4]]) {
      cache.set('store', p as string, { path: p as string, value: v, type: 'integer', seq: v as number });
    }
    return cache;
  };

  it('returns entries matching pattern with default order asc', () => {
    const cache = setup();
    const page = cache.browse('store', { pattern: 'a.*', limit: 50 });
    expect(page.items.map((e: Entry) => e.path)).toEqual(['a.1', 'a.2', 'a.3']);
    expect(page.nextCursor).toBeNull();
  });

  it('honors limit + next_cursor', () => {
    const cache = setup();
    const page = cache.browse('store', { pattern: '**', limit: 2 });
    expect(page.items.map((e: Entry) => e.path)).toEqual(['a.1', 'a.2']);
    expect(page.nextCursor).toEqual('a.2');
  });

  it('resumes from cursor', () => {
    const cache = setup();
    const page = cache.browse('store', { pattern: '**', limit: 2, after: 'a.2' });
    expect(page.items.map((e: Entry) => e.path)).toEqual(['a.3', 'b.1']);
  });

  it('supports order desc', () => {
    const cache = setup();
    const page = cache.browse('store', { pattern: '**', limit: 10, order: 'desc' });
    expect(page.items.map((e: Entry) => e.path)).toEqual(['b.1', 'a.3', 'a.2', 'a.1']);
  });

  it('supports select keys', () => {
    const cache = setup();
    const page = cache.browse('store', { pattern: '**', limit: 10, select: 'keys' });
    expect(page.items).toEqual(['a.1', 'a.2', 'a.3', 'b.1']);
  });

  it('supports select prefixes for ** pattern', () => {
    const cache = new MemoryCache();
    for (const p of ['users.alice.name', 'users.bob.name', 'posts.hi']) {
      cache.set('store', p, { path: p, value: 1, type: 'integer', seq: 1 });
    }
    const page = cache.browse('store', { pattern: '**', limit: 10, select: 'prefixes' });
    expect(page.items).toEqual(['posts', 'users']);
  });

  it('supports select prefixes for users.** pattern', () => {
    const cache = new MemoryCache();
    for (const p of ['users.alice.name', 'users.alice.email', 'users.bob.name']) {
      cache.set('store', p, { path: p, value: 1, type: 'integer', seq: 1 });
    }
    const page = cache.browse('store', { pattern: 'users.**', limit: 10, select: 'prefixes' });
    expect(page.items).toEqual(['users.alice', 'users.bob']);
  });

  it('rejects select prefixes with invalid pattern', () => {
    const cache = new MemoryCache();
    expect(() => cache.browse('store', { pattern: 'a.*.b', limit: 10, select: 'prefixes' })).toThrow(/prefixes/);
  });
});
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

Interface:
```typescript
interface BrowseOptions {
  pattern?: string;
  from?: string;
  to?: string;
  limit?: number;
  after?: string;
  order?: 'asc' | 'desc';
  select?: 'entries' | 'keys' | 'prefixes';
}

// Function overloads for narrow return types
browse(store: string, opts: BrowseOptions & { select: 'keys' | 'prefixes' }): Page<string>;
browse(store: string, opts: BrowseOptions & { select?: 'entries' }): Page<Entry>;
browse(store: string, opts: BrowseOptions): Page<Entry> | Page<string>;
```

Impl skeleton (port from Elixir Ecto / Crystal SQLite logic):

```typescript
browse(store: string, opts: BrowseOptions): Page<Entry> | Page<string> {
  const pattern = opts.pattern ?? '**';
  const limit = opts.limit ?? 50;
  const order = opts.order ?? 'asc';
  const select = opts.select ?? 'entries';

  // Validate prefixes pattern up front
  if (select === 'prefixes') {
    if (pattern !== '**' && !pattern.endsWith('.**')) {
      throw new Error('select: prefixes requires pattern ending in .** or **');
    }
  }

  // Collect candidate entries
  const storeMap = this.stores.get(store);
  if (!storeMap) return { items: [], nextCursor: null };

  let entries: Entry[] = Array.from(storeMap.values());

  // Filter
  if (opts.from !== undefined && opts.to !== undefined) {
    // Range mode
    entries = entries.filter((e) => e.path >= opts.from! && e.path < opts.to!);
  } else {
    // Glob mode
    entries = entries.filter((e) => match(pattern, e.path));
  }

  // Sort
  entries.sort((a, b) => order === 'asc' ? a.path.localeCompare(b.path) : b.path.localeCompare(a.path));

  // Cursor
  if (opts.after !== undefined) {
    entries = order === 'asc'
      ? entries.filter((e) => e.path > opts.after!)
      : entries.filter((e) => e.path < opts.after!);
  }

  // Take limit + 1 to detect next cursor
  const page = entries.slice(0, limit + 1);
  const hasMore = page.length > limit;
  const pageItems = hasMore ? page.slice(0, limit) : page;
  const nextCursor = hasMore && pageItems.length > 0
    ? pageItems[pageItems.length - 1].path
    : null;

  // Project
  if (select === 'entries') {
    return { items: pageItems, nextCursor };
  } else if (select === 'keys') {
    return { items: pageItems.map((e) => e.path), nextCursor };
  } else {
    // prefixes
    return { items: prefixesOf(pageItems, pattern), nextCursor };
  }
}

function prefixesOf(entries: Entry[], pattern: string): string[] {
  const literal = literalPrefixOf(pattern);
  const seen = new Set<string>();
  for (const entry of entries) {
    const prefix = extractPrefix(entry.path, literal);
    if (prefix !== null) seen.add(prefix);
  }
  return Array.from(seen).sort();
}

function literalPrefixOf(pattern: string): string {
  if (pattern === '**') return '';
  return pattern.replace(/\.\*\*$/, '');
}

function extractPrefix(path: string, literal: string): string | null {
  if (literal === '') {
    const i = path.indexOf('.');
    return i === -1 ? path : path.slice(0, i);
  }
  const prefix = literal + '.';
  if (!path.startsWith(prefix)) return null;
  const rest = path.slice(prefix.length);
  const i = rest.indexOf('.');
  return literal + '.' + (i === -1 ? rest : rest.slice(0, i));
}
```

Place `prefixesOf`/`literalPrefixOf`/`extractPrefix` as module-level helpers in `cache.ts` (not class methods — they're pure functions).

**KNOWN LIMITATION:** Unlike Elixir Ecto's post-Phase-1-C1 chunked fetch, this in-memory `Map.values()` walk reads the **entire store** on every `browse` call and filters in JS. Acceptable for MVP — the cache is small, and all operations are O(n) in the store size regardless. Document with a code comment near the filter step. If perf becomes an issue, we can add sorted indexes later.

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Cache.browse with pattern, cursor, limit, order, select`

---

### Task 5: `Cache.browse` range support (`from`/`to`)

**Files:**
- Modify: `sdk/typescript/test/cache.test.ts`

**Note:** Task 4's `browse` already includes the range filter branch via `opts.from`/`opts.to`. This task adds the range-specific tests to verify the branch works correctly. If any tests fail, fix the range branch; otherwise just commit the tests.

**Step 1: Failing tests**

```typescript
describe('browse range', () => {
  const setup = () => {
    const cache = new MemoryCache();
    for (const p of ['a', 'b', 'c', 'd', 'e']) {
      cache.set('store', p, { path: p, value: p, type: 'string', seq: 1 });
    }
    return cache;
  };

  it('returns entries in [from, to)', () => {
    const cache = setup();
    const page = cache.browse('store', { from: 'b', to: 'd', limit: 10 });
    expect((page.items as Entry[]).map((e) => e.path)).toEqual(['b', 'c']);
  });

  it('from is inclusive, to is exclusive', () => {
    const cache = setup();
    const page = cache.browse('store', { from: 'a', to: 'c', limit: 10 });
    expect((page.items as Entry[]).map((e) => e.path)).toEqual(['a', 'b']);
  });

  it('from >= to returns empty', () => {
    const cache = setup();
    const page = cache.browse('store', { from: 'z', to: 'a', limit: 10 });
    expect(page.items).toEqual([]);
  });

  it('range respects order desc', () => {
    const cache = setup();
    const page = cache.browse('store', { from: 'a', to: 'd', limit: 10, order: 'desc' });
    expect((page.items as Entry[]).map((e) => e.path)).toEqual(['c', 'b', 'a']);
  });

  it('range with limit + cursor paginates', () => {
    const cache = setup();
    const page1 = cache.browse('store', { from: 'a', to: 'z', limit: 2 });
    expect((page1.items as Entry[]).map((e) => e.path)).toEqual(['a', 'b']);
    expect(page1.nextCursor).toEqual('b');

    const page2 = cache.browse('store', { from: 'a', to: 'z', limit: 2, after: 'b' });
    expect((page2.items as Entry[]).map((e) => e.path)).toEqual(['c', 'd']);
  });
});
```

**Step 2: Run. If all green, Task 4's implementation was correct; if any fail, fix the range branch in `browse`.**

**Step 3: Commit**

Message: `test(sdk-ts): browse supports from/to range filter`

---

### Task 6: `Dust.entry()` method

**Files:**
- Modify: `sdk/typescript/src/dust.ts`
- Modify: `sdk/typescript/test/dust.test.ts`

**Step 1: Failing test**

Look at how existing `dust.test.ts` tests are structured — they probably use a mock Connection. Mirror that pattern. Example:

```typescript
it('entry returns the cached Entry for a present path', async () => {
  const dust = createTestDust();
  await seedEntry(dust, 'store', 'users.alice.name', 'Alice', 'string', 7);
  const result = await dust.entry('store', 'users.alice.name');
  expect(result).toEqual({
    path: 'users.alice.name',
    value: 'Alice',
    type: 'string',
    seq: 7,
  });
});

it('entry returns null for a missing path', async () => {
  const dust = createTestDust();
  const result = await dust.entry('store', 'no.such');
  expect(result).toBeNull();
});
```

**IMPORTANT:** `createTestDust` and `seedEntry` are hypothetical helpers — if `dust.test.ts` doesn't have them, figure out the existing pattern (likely instantiating `Dust` with a mock Connection and manually feeding events to populate the cache). Match whatever exists.

**Step 2: Run — FAIL.**

**Step 3: Implement**

```typescript
// sdk/typescript/src/dust.ts
async entry(store: string, path: string): Promise<Entry | null> {
  await this.ensureJoined(store);
  return this.cache.readEntry(store, path);
}
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Dust.entry returns cached entry with metadata`

---

### Task 7: `Dust.enum()` overload with `EnumOptions` + `Page<T>` return

**Files:**
- Modify: `sdk/typescript/src/dust.ts`
- Modify: `sdk/typescript/test/dust.test.ts`

**Step 1: Failing tests**

```typescript
it('enum with no opts preserves the flat array shape (backwards compat)', async () => {
  const dust = createTestDust();
  await seedEntry(dust, 'store', 'a', 1, 'integer', 1);
  await seedEntry(dust, 'store', 'b', 2, 'integer', 2);
  const result = await dust.enum('store', '**');
  expect(Array.isArray(result)).toBe(true);
  expect(result).toHaveLength(2);
});

it('enum with opts returns a Page', async () => {
  const dust = createTestDust();
  for (const k of ['a', 'b', 'c']) {
    await seedEntry(dust, 'store', k, k, 'string', 1);
  }
  const page = await dust.enum('store', '**', { limit: 2 });
  expect(page.items).toHaveLength(2);
  expect(page.nextCursor).toBeTruthy();
});

it('enum with select keys returns string array', async () => {
  const dust = createTestDust();
  for (const k of ['a', 'b']) {
    await seedEntry(dust, 'store', k, k, 'string', 1);
  }
  const page = await dust.enum('store', '**', { select: 'keys' });
  expect(page.items).toEqual(['a', 'b']);
});
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

Add overloads to `Dust.enum`:

```typescript
// In Dust class
async enum(store: string, pattern: string): Promise<Entry[]>;
async enum(
  store: string,
  pattern: string,
  opts: EnumOptions & { select: 'keys' | 'prefixes' }
): Promise<Page<string>>;
async enum(
  store: string,
  pattern: string,
  opts: EnumOptions & { select?: 'entries' }
): Promise<Page<Entry>>;
async enum(
  store: string,
  pattern: string,
  opts?: EnumOptions
): Promise<Entry[] | Page<Entry> | Page<string>> {
  await this.ensureJoined(store);

  if (opts === undefined) {
    // Legacy shape
    return this.cache.entries(store, pattern);
  }

  return this.cache.browse(store, { ...opts, pattern });
}
```

And add `EnumOptions` to `types.ts`:

```typescript
export interface EnumOptions {
  limit?: number;
  after?: string;
  order?: 'asc' | 'desc';
  select?: 'entries' | 'keys' | 'prefixes';
}
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Dust.enum overload with EnumOptions and Page return`

---

### Task 8: `Dust.range()` method

**Files:**
- Modify: `sdk/typescript/src/dust.ts`
- Modify: `sdk/typescript/test/dust.test.ts`

**Step 1: Failing tests**

```typescript
it('range returns entries in [from, to)', async () => {
  const dust = createTestDust();
  for (const k of ['a', 'b', 'c', 'd', 'e']) {
    await seedEntry(dust, 'store', k, k, 'string', 1);
  }
  const page = await dust.range('store', 'b', 'e', { limit: 10 });
  expect(page.items.map((e: Entry) => e.path)).toEqual(['b', 'c', 'd']);
});

it('range rejects select prefixes', async () => {
  const dust = createTestDust();
  await expect(dust.range('store', 'a', 'z', { select: 'prefixes' as any }))
    .rejects.toThrow();
});

it('range with from >= to returns empty page', async () => {
  const dust = createTestDust();
  await seedEntry(dust, 'store', 'x', 'x', 'string', 1);
  const page = await dust.range('store', 'z', 'a');
  expect(page.items).toEqual([]);
  expect(page.nextCursor).toBeNull();
});
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

```typescript
// In Dust class
async range(
  store: string,
  from: string,
  to: string,
  opts: Omit<EnumOptions, 'select'> & { select?: 'entries' | 'keys' } = {}
): Promise<Page<Entry> | Page<string>> {
  if (opts.select === 'prefixes' as any) {
    throw new Error('range: select prefixes is not supported');
  }
  await this.ensureJoined(store);
  return this.cache.browse(store, { ...opts, from, to });
}
```

Note the `select: 'prefixes'` rejection — it's an "any" cast because the type already excludes it, but runtime safety is useful for callers who cast their way past the type check.

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Dust.range reads entries in [from, to) with cursor pagination`

---

### Task 9: `Dust.getMany()` method

**Files:**
- Modify: `sdk/typescript/src/dust.ts`
- Modify: `sdk/typescript/test/dust.test.ts`

**Step 1: Failing tests**

```typescript
it('getMany returns a record of present values', async () => {
  const dust = createTestDust();
  await seedEntry(dust, 'store', 'a', 1, 'integer', 1);
  await seedEntry(dust, 'store', 'b', 2, 'integer', 2);
  const result = await dust.getMany('store', ['a', 'b']);
  expect(result).toEqual({ a: 1, b: 2 });
});

it('getMany omits missing paths', async () => {
  const dust = createTestDust();
  await seedEntry(dust, 'store', 'a', 1, 'integer', 1);
  expect(await dust.getMany('store', ['a', 'missing'])).toEqual({ a: 1 });
});

it('getMany with empty list returns empty object', async () => {
  const dust = createTestDust();
  expect(await dust.getMany('store', [])).toEqual({});
});

it('getMany with > 1000 paths throws', async () => {
  const dust = createTestDust();
  const paths = Array.from({ length: 1001 }, (_, i) => `p.${i}`);
  await expect(dust.getMany('store', paths)).rejects.toThrow(/1000/);
});
```

**Step 2: Run — FAIL.**

**Step 3: Implement**

```typescript
async getMany(store: string, paths: string[]): Promise<Record<string, unknown>> {
  if (paths.length > 1000) {
    throw new Error('getMany: maximum 1000 paths per call');
  }
  await this.ensureJoined(store);
  const raw = this.cache.readMany(store, paths);
  const result: Record<string, unknown> = {};
  for (const [path, entry] of Object.entries(raw)) {
    result[path] = entry.value;
  }
  return result;
}
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Dust.getMany returns record of present values`

---

### Task 10: `Dust.watch()` — async bootstrap watch

**Files:**
- Modify: `sdk/typescript/src/dust.ts`
- Modify: `sdk/typescript/src/types.ts` (add `PresentEvent` or union)
- Modify: `sdk/typescript/test/dust.test.ts`

**Step 1: Failing tests**

```typescript
describe('watch', () => {
  it('dispatches current matching entries as present events before live events', async () => {
    const dust = createTestDust();
    await seedEntry(dust, 'store', 'users.alice.name', 'Alice', 'string', 1);
    await seedEntry(dust, 'store', 'users.bob.name', 'Bob', 'string', 2);

    const received: WatchEvent[] = [];
    const unsubscribe = await dust.watch('store', 'users.**', (event) => {
      received.push(event);
    });

    expect(received).toHaveLength(2);
    expect(received[0]).toMatchObject({ op: 'present', path: 'users.alice.name' });
    expect(received[1]).toMatchObject({ op: 'present', path: 'users.bob.name' });

    unsubscribe();
  });

  it('watch honors limit and order', async () => {
    const dust = createTestDust();
    for (let i = 1; i <= 10; i++) {
      await seedEntry(dust, 'store', `k.${i}`, i, 'integer', i);
    }
    const received: WatchEvent[] = [];
    await dust.watch('store', 'k.**', (e) => { received.push(e); }, { limit: 3 });
    expect(received).toHaveLength(3);
  });

  it('watch with no matches returns unsubscribe without emitting', async () => {
    const dust = createTestDust();
    const received: WatchEvent[] = [];
    const unsubscribe = await dust.watch('store', 'no.match.**', (e) => { received.push(e); });
    expect(received).toEqual([]);
    expect(typeof unsubscribe).toBe('function');
    unsubscribe();
  });

  it('live events that arrive during bootstrap hydration are buffered and drained after', async () => {
    // This is the tricky race test. Implementation detail:
    // 1. Start watch (registers sub with bootstrapPending: true)
    // 2. Simulate an incoming live event BEFORE bootstrap completes
    // 3. Verify the event is buffered, not delivered immediately
    // 4. Verify it's delivered AFTER the bootstrap present events
    //
    // This test requires injecting an event into the SDK mid-watch.
    // How to do it: hold a resolver for ensureJoined, fire a live event,
    // then resolve ensureJoined. OR use a mock Connection that lets
    // you trigger events manually.
    //
    // SUBAGENT: if dust.test.ts has a `triggerEvent` helper or similar,
    // use it. Otherwise, skip this test and rely on visual review.
    // It's hard to write without the right hooks.
  });
});
```

Note: the 4th test above is ambitious. If the existing test infrastructure supports mid-test event injection, write it. If not, skip it and document in a TODO — the race-free guarantee is mostly about JS single-threadedness, which doesn't need a runtime test to validate.

**Step 2: Run — FAIL.**

**Step 3: Implement**

Update `Subscription` type:

```typescript
interface Subscription {
  pattern: string;
  callback: (event: Event | PresentEvent) => void;
  bootstrapPending: boolean;
  pendingEvents: Event[];
}
```

Add the `watch` method:

```typescript
async watch(
  store: string,
  pattern: string,
  callback: (event: Event | PresentEvent) => void,
  opts: { limit?: number; order?: 'asc' | 'desc' } = {}
): Promise<() => void> {
  const limit = Math.min(opts.limit ?? 50, 1000);
  const order = opts.order ?? 'asc';

  const sub: Subscription = {
    pattern,
    callback,
    bootstrapPending: true,
    pendingEvents: [],
  };

  const storeSubs = this.subscriptionsFor(store); // existing helper or direct access
  storeSubs.add(sub);
  const unsubscribe = () => storeSubs.delete(sub);

  try {
    await this.ensureJoined(store);

    const page = this.cache.browse(store, {
      pattern,
      limit,
      order,
      select: 'entries',
    }) as Page<Entry>;

    // Synchronously dispatch bootstrap — no await in this loop
    for (const entry of page.items) {
      callback({
        op: 'present',
        path: entry.path,
        value: entry.value,
        type: entry.type,
        seq: entry.seq,
      });
    }

    // Drain any live events that queued during hydration
    for (const event of sub.pendingEvents) {
      callback(event);
    }
    sub.pendingEvents = [];
    sub.bootstrapPending = false;
  } catch (err) {
    unsubscribe();
    throw err;
  }

  return unsubscribe;
}
```

Update `handleEvent` (or wherever subscriptions are dispatched) to respect `bootstrapPending`:

```typescript
// In the existing event dispatch loop:
for (const sub of storeSubs) {
  if (match(sub.pattern, event.path)) {
    if (sub.bootstrapPending) {
      sub.pendingEvents.push(event);
    } else {
      sub.callback(event);
    }
  }
}
```

**IMPORTANT:** Existing `on()` subscriptions created without `bootstrapPending` — make sure the old code path still works. Either default `bootstrapPending: false` everywhere or make the property optional and check with `if (sub.bootstrapPending)`.

Add `PresentEvent` to `types.ts`:

```typescript
export interface PresentEvent {
  op: 'present';
  path: string;
  value: unknown;
  type: string;
  seq: number;
}
```

**Step 4: Run — PASS.**

**Step 5: Commit**

Message: `feat(sdk-ts): Dust.watch awaits catch-up and dispatches current entries before live`

---

### Task 11: End-to-end verification

**Files:** none modified.

**Step 1:** Full test run:

```bash
cd sdk/typescript && npm test
```

Expected: all previous tests (75) still pass, plus ~30-35 new tests from Phase 4b. Total ~105-110 tests.

**Step 2:** Type check:

```bash
npx tsc --noEmit
```

Expected: clean.

**Step 3:** If the repo has lint:

```bash
npm run lint 2>/dev/null || echo "no lint script"
```

Fix any warnings.

**Step 4: No commit needed.**

---

## Verification checklist

- [ ] `Page<T>` type exported.
- [ ] `Cache.readEntry`/`readMany`/`browse` added to interface.
- [ ] `MemoryCache` implements all three.
- [ ] `browse` supports pattern, cursor, limit, order, select (`entries` | `keys` | `prefixes`).
- [ ] `browse` supports `from`/`to` range filter.
- [ ] `Dust.entry()` returns `Entry | null`.
- [ ] `Dust.enum()` overload: no opts → `Entry[]` (legacy); with opts → `Page<Entry>`/`Page<string>`.
- [ ] `Dust.range()` returns `Page<Entry>`/`Page<string>`, rejects `select: prefixes`.
- [ ] `Dust.getMany()` returns `Record<string, unknown>`, dedupes input, caps at 1000.
- [ ] `Dust.watch()` is async, awaits catch-up, emits `PresentEvent`s synchronously, buffers live events during hydration.
- [ ] Existing `on()` subscriptions still work unchanged.
- [ ] All existing 75 tests still pass.
- [ ] `tsc --noEmit` is clean.

## Cross-SDK parity check

All new read features are expressible against the in-memory `Map` cache — no async, no SQL. When/if we port to IndexedDB or a persistent cache, the same logic maps cleanly to a SQL-backed store because the operations are all:
- Point lookup by path
- `IN` list by paths
- Range / prefix filter + ORDER BY + LIMIT

Cross-SDK schema parity: the TS cache is in-memory only. Its "schema" is the `Entry` interface — `{path, value, type, seq}` — which already matches the Elixir/Crystal `(path, value, type, seq)` columns byte-for-byte.

## Known limitations

1. **In-memory only.** No persistence. If this becomes a pain for long-lived browser-side caches, add an IndexedDB adapter as a later phase.
2. **Full-scan `browse`.** Every call walks the entire store map. O(n) per call. Acceptable for store sizes up to ~10k entries. If this becomes a bottleneck, add sorted indexes.
3. **The "live event during bootstrap" test** (Task 10, 4th case) may be hard to write cleanly without mock injection helpers. If the existing test infra doesn't support it, skip and rely on code review + the JS single-thread argument.

## Process reminder

Subagents implement + test + report. The main session commits.
