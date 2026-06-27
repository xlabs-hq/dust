# Segment-First Paths with Slash Rendering - Design and Migration Plan

**Date:** 2026-05-12
**Status:** Proposed

## Recommendation

Move Dust paths to a segment-first model. A path is not fundamentally a dotted
or slashed string; it is an ordered list of nonempty string segments:

```text
Path = nonempty list of nonempty string segments
```

Public SDK APIs should prefer the segment form and accept slash-rendered
strings as a convenience:

```elixir
Dust.put(store, ["posts", "hello.world", "title"], value)
Dust.put(store, "posts/hello.world/title", value)
```

The slash string is the canonical **rendering**, not the semantic model. Use it
where a string is required: URLs, SQLite keys, CLI arguments, logs, webhook
payloads, export files, and human-readable docs.

The canonical rendering uses `/` between segments and JSON Pointer-style
escaping inside each segment:

```text
segments: ["posts", "hello.world", "image/file", "a~b"]
rendered: posts/hello.world/image~1file/a~0b
```

Escaping rules:

- `~` encodes as `~0`
- `/` encodes as `~1`
- `.` has no special meaning
- raw `/` separates hierarchy levels in rendered strings
- raw `~` is invalid in rendered strings unless it starts `~0` or `~1`
- empty paths and empty segments are invalid

This replaces the current delimiter-based dotted path model. Dotted paths were
ergonomic initially, but they made dots impossible in keys, created special
REST handling, and encouraged unsafe call-site string interpolation.

## Why Change

Today, Dust treats paths as dotted strings, with slashes accepted as aliases:

```text
projects.alpha.title
projects/alpha/title -> projects.alpha.title
```

This has three structural problems:

1. **Literal dots cannot be represented.**
   Keys like domains, emails, filenames, package names, and version labels are
   common in real data. `"example.com"` should be one segment, not two.

2. **REST paths need a special boundary rule.**
   The HTTP API currently accepts `/entries/foo/bar` and rejoins URL segments
   into `foo.bar`, while rejecting dots inside URL segments to avoid ambiguity.
   That is workable, but it is a sign that the data model and URL rendering
   are fighting each other.

3. **Manual path construction is unsafe.**
   Several code paths build children with interpolation like
   `#{prefix}.#{key}`. With delimiter-based paths, map keys can silently change
   hierarchy if they contain the delimiter.

The long-term fix is not "use `/` instead of `.` everywhere" by itself. The
fix is to make path segments authoritative, then render them consistently at
string boundaries.

## Target Contract

### Path Values

The authoritative path value is a segment list:

```text
["users", "alice", "profile.email"]
["files", "readme/draft"]
["packages", "@scope", "name"]
```

Segments:

- must be strings
- must be nonempty
- may contain `.`
- may contain `/`
- may contain `~`

### Canonical Rendering

Canonical rendered paths are slash-separated encoded segments:

```text
users/alice/profile.email
files/readme~1draft
packages/@scope/name
```

Decoded examples:

```text
users/alice/profile.email -> ["users", "alice", "profile.email"]
files/readme~1draft       -> ["files", "readme/draft"]
packages/@scope/name      -> ["packages", "@scope", "name"]
```

Invalid rendered paths:

```text
""              # empty path
"/users"        # empty first segment
"users/"        # empty last segment
"users//alice"  # empty middle segment
"a~b"           # invalid escape
"a~2b"          # invalid escape
```

### Public SDK APIs

SDKs should expose segment lists as the exact, preferred API and slash strings
as a convenience parser:

```elixir
Dust.put(store, ["posts", "hello.world", "title"], value)
Dust.get(store, ["files", "readme/draft"])
Dust.on(store, ["posts", "*", "title"], callback)
```

String convenience:

```elixir
Dust.put(store, "posts/hello.world/title", value)
Dust.get(store, "files/readme~1draft")
Dust.on(store, "posts/*/title", callback)
```

Returned entries and events may include rendered `path` strings for display and
compatibility, but SDK internals should normalize immediately to segment lists
or canonical rendered keys through one path module.

### URLs

The REST path form uses the canonical rendering:

```text
GET    /api/stores/:org/:store/entries/posts/hello.world/title
PUT    /api/stores/:org/:store/entries/posts/hello.world/title
DELETE /api/stores/:org/:store/entries/posts/hello.world/title
```

Literal slash inside a segment uses `~1`, not `%2F`:

```text
segments: ["files", "readme/draft"]
URL:      /api/stores/:org/:store/entries/files/readme~1draft
```

Normal URL percent-encoding still applies for characters that are not safe in
URLs, but the Dust path decoder runs after the framework has decoded the URL.
Do not rely on `%2F` for literal slash segments; many routers split on slash
before or during percent decoding.

### Glob Patterns

Glob patterns are segment-aware. The preferred exact API is segment lists:

```elixir
Dust.on(store, ["posts", "*", "title"], callback)
Dust.on(store, ["posts", "**"], callback)
```

The string convenience form uses the same slash rendering:

```text
posts/*/title
posts/**
users/alice/*
```

Semantics:

- `*` matches exactly one segment.
- `**` matches one or more segments.
- Wildcards are active only when the decoded pattern segment is exactly `*` or
  `**`.
- `**` should remain tail-only unless there is a specific product reason to
  support middle-recursive matching.

Literal path segments named `*` or `**` are rare but possible for direct entry
APIs. Exact glob matching for those literal wildcard tokens can be deferred; if
the product needs it, add an explicit glob escaping rule in a separate design
rather than overloading path escaping.

### Storage

Keep the SQLite schema shape:

```sql
path TEXT PRIMARY KEY
```

Store canonical rendered paths in that column. This avoids a schema migration
and preserves lexicographic scans.

Descendant operations use canonical rendered prefixes:

```elixir
prefix = rendered_path <> "/"
```

No production code should build paths by string interpolation. Child paths must
be built through the path module from segment values.

### Wire Protocol

For the new capability version, path segments should be the authoritative wire
value where the transport supports structured data. JSON and MessagePack both
do, so new write payloads and events should carry `path_segments`:

```json
{
  "op": "set",
  "path_segments": ["posts", "hello.world", "title"],
  "value": "Hello"
}
```

During migration, events may also include a rendered `path` string:

```json
{
  "op": "set",
  "path_segments": ["posts", "hello.world", "title"],
  "path": "posts/hello.world/title",
  "value": "Hello"
}
```

The protocol should bump capability version. Dotted paths cannot represent
literal-dot segments safely, so indefinite transparent translation is not a
good long-term contract. Use a short migration window only if needed.

## API Design

Create a single path API and push all code through it. The API should make
segments explicit and treat string parsing/rendering as boundary operations.

Suggested Elixir API:

```elixir
DustProtocol.Path.from_segments(["posts", "hello.world", "image/file"])
# {:ok, %DustProtocol.Path{segments: ["posts", "hello.world", "image/file"]}}

DustProtocol.Path.parse_rendered("posts/hello.world/image~1file")
# {:ok, %DustProtocol.Path{segments: ["posts", "hello.world", "image/file"]}}

DustProtocol.Path.render(["posts", "hello.world", "image/file"])
# {:ok, "posts/hello.world/image~1file"}

DustProtocol.Path.normalize_rendered("posts/hello.world/image~1file")
# {:ok, "posts/hello.world/image~1file"}

DustProtocol.Path.child(["posts", "hello.world"], "image/file")
# {:ok, ["posts", "hello.world", "image/file"]}

DustProtocol.Path.render_descendant_prefix(["posts", "hello.world"])
# "posts/hello.world/"

DustProtocol.Path.ancestor?(["posts"], ["posts", "hello.world"])
# true
```

Keep legacy helpers separate and visibly named:

```elixir
DustProtocol.Path.LegacyDot.parse("posts.hello.title")
DustProtocol.Path.LegacyDot.to_segments("posts.hello.title")
DustProtocol.Path.LegacyDot.to_rendered("posts.hello.title")
```

Do not keep slash-as-dot aliases in the new path API. They are part of the
problem.

## Implementation Scope

### Protocol Package

Files:

- `protocol/elixir/lib/dust_protocol/path.ex`
- `protocol/elixir/lib/dust_protocol/glob.ex`
- `protocol/spec/sync-semantics.md`
- `protocol/spec/asyncapi.yaml`
- `protocol/spec/fixtures/path_vectors.json`
- `protocol/spec/fixtures/glob_vectors.json`

Work:

1. Replace dot splitting with segment-aware parsing.
2. Add `from_segments`, rendered parse/render/normalize, child, ancestor, and
   descendant-prefix helpers.
3. Add strict invalid escape handling for rendered strings.
4. Update glob compiler and matcher to operate on segment lists.
5. Add legacy dotted conversion helpers for migration only.
6. Update protocol fixtures and tests.
7. Bump protocol capability version for segment-first paths.

### Server

Files and areas:

- `server/lib/dust/sync/value_codec.ex`
- `server/lib/dust/sync/writer.ex`
- `server/lib/dust/sync.ex`
- `server/lib/dust/sync/audit.ex`
- `server/lib/dust/sync/rollback.ex`
- `server/lib/dust/glob.ex`
- `server/lib/dust_web/router.ex`
- `server/lib/dust_web/controllers/api/entries_api_controller.ex`
- `server/lib/dust_web/api_spec.ex`
- MCP tools under `server/lib/dust/mcp/tools/`

Work:

1. Validate every incoming write path through the new path module.
2. Accept segment-list paths where the boundary supports structured data.
3. Accept rendered string paths only as convenience input.
4. Store canonical rendered paths in SQLite.
5. Change map flattening to build child segments through `Path.child/2`.
6. Change subtree deletes and subtree reads from `path <> "."` to rendered
   descendant prefixes.
7. Change materialized subtree assembly to parse relative child paths by
   segments, not string-split on dots.
8. Update REST route handling so `*path` is decoded as rendered slash paths;
   remove the current "URL segment cannot contain dot" rule.
9. Update OpenAPI path docs and examples.
10. Update audit, rollback, import, export, diff, and webhook docs/examples to
   report rendered slash paths and, where useful, segment arrays.
11. Normalize or reject MCP tool paths consistently.

### Elixir SDK

Files and areas:

- `sdk/elixir/lib/dust/protocol/path.ex`
- `sdk/elixir/lib/dust/protocol/glob.ex`
- `sdk/elixir/lib/dust/sync_engine.ex`
- `sdk/elixir/lib/dust/cache/memory.ex`
- `sdk/elixir/lib/dust/cache/ecto.ex`
- `sdk/elixir/lib/dust/callback_registry.ex`
- docs and tests under `sdk/elixir/`

Work:

1. Mirror the path API from `DustProtocol.Path`.
2. Add public overloads accepting `String.t()` or `[String.t()]`.
3. Prefer segment lists in docs and examples.
4. Replace all `String.split(path, ".")` calls.
5. Replace prefix extraction and prefix listing logic with segment-aware
   helpers.
6. Ensure cache keys are stored as canonical rendered paths.

### TypeScript SDK

Files and areas:

- `sdk/typescript/src/path.ts`
- `sdk/typescript/src/glob.ts`
- `sdk/typescript/src/cache.ts`
- `sdk/typescript/src/dust.ts`
- `sdk/typescript/dist/*`
- tests under `sdk/typescript/test/`

Work:

1. Define `type PathInput = string | string[]`.
2. Implement `parseRenderedPath`, `renderPath`, `normalizePathInput`, and
   child/prefix helpers.
3. Prefer `string[]` examples in docs and tests.
4. Update cache browse, prefix listing, range, and glob matching.
5. Update generated dist files.
6. Add parity tests with protocol fixtures.

### Crystal CLI

Files and areas:

- `cli/src/dust/glob.cr`
- `cli/src/dust/cache/sqlite.cr`
- `cli/src/dust/commands/*.cr`
- tests under `cli/spec/`

Work:

1. Add canonical rendered path parse/encode logic or share generated fixtures.
2. Update glob matching and cache prefix queries.
3. Update command help and examples.

The CLI remains string-first because shell arguments are strings. It should use
rendered slash paths and should not support dotted aliases.

### Ecto Adapter

Files and areas:

- `sdk/elixir_ecto/lib/dust_ecto/repo.ex`
- `sdk/elixir_ecto/lib/dust_ecto/transport/http.ex`
- `sdk/elixir_ecto/lib/dust_ecto/transport/sdk.ex`
- tests under `sdk/elixir_ecto/test/`

Work:

1. Stop building paths as `#{prefix}.#{slug}.#{field}`.
2. Treat configured prefixes as segment lists or rendered slash paths.
3. Build record paths from `[prefix_segments, slug, field_segments]`.
4. Preserve literal dots in slugs and fields.
5. Decide whether slugs may contain literal `/`; if yes, encode with `~1`.

## Migration Plan

### Preflight

Before rewriting store files, scan each store for collisions.

Legacy conversion rule:

```text
old dotted path: posts.hello.title
new segments:    ["posts", "hello", "title"]
new rendered:    posts/hello/title
```

The old system could not safely distinguish a literal dot key from nested
segments after flattening. Migration must treat existing dotted paths as dotted
hierarchies. If an old invalid write already collapsed two intended shapes into
one path, that information is unrecoverable from `store_entries`.

Preflight should check:

- every old path parses as legacy dotted path
- every converted rendered path is unique
- snapshots and ops can be converted consistently
- any cached client cursor or local cache metadata that embeds paths is either
  converted or invalidated

### Rewrite

For each store SQLite file:

1. Open a write connection.
2. Begin transaction.
3. Read `store_entries.path`, convert to rendered slash path, rewrite rows.
4. Read `store_ops.path`, convert to rendered slash path, rewrite rows.
5. Decode `store_snapshots.snapshot_data`, convert every object key, rewrite.
6. Commit.
7. Vacuum if appropriate.

Postgres store metadata does not need schema changes if it only tracks counts
and seqs.

### Rollout Shape

Recommended rollout:

1. Land path modules and tests.
2. Land server support behind new capver.
3. Land SDK/CLI support.
4. Run migration in staging.
5. Reject old capver clients after migration.
6. Migrate production stores.
7. Remove dotted compatibility once there are no old clients.

Avoid keeping dotted and rendered slash paths live indefinitely. It creates a
permanent ambiguity tax and makes literal-dot support unreliable.

## Test Plan

Path tests:

- `["hello.world"]` renders to `hello.world` and remains one segment.
- `["image/file"]` renders to `image~1file`.
- `["a~b"]` renders to `a~0b`.
- `image~1file` decodes to `["image/file"]`.
- `a~0b` decodes to `["a~b"]`.
- invalid `~`, `~2`, leading slash, trailing slash, and double slash reject.
- `render(parse_rendered(path)) == path` for canonical rendered inputs.
- `parse_rendered(render(segments)) == segments` for arbitrary valid segments.

Server tests:

- write and read using segment-list input.
- write and read using rendered string convenience input.
- write and read path with literal dot segment.
- write and read path with literal slash segment via `~1`.
- write and read path with literal tilde via `~0`.
- map flattening preserves keys containing dots.
- map flattening preserves keys containing slash by encoding child paths.
- subtree delete deletes only descendants, not same-prefix siblings.
- subtree read materializes nested maps correctly.
- range and pagination still sort by rendered path key.
- import/export round trip rendered paths.
- rollback and diff work with rendered paths.
- webhook payloads contain rendered paths and, if adopted, segment arrays.
- REST round trip with dots, escaped slashes, and escaped tildes.

Glob tests:

- `["posts", "*", "title"]` matches `["posts", "hello.world", "title"]`.
- `posts/*/title` matches `posts/hello.world/title`.
- `posts/*` does not match `posts/a/b`.
- `posts/**` matches descendants.
- `posts/**` does not match `posts` if `**` remains one-or-more.
- wildcard behavior is segment-based, not substring-based.

SDK/CLI tests:

- SDK calls accept segment lists.
- SDK calls accept rendered string convenience.
- local cache keys are rendered slash paths.
- memory and SQLite/Ecto cache browsing agree.
- prefix listing returns rendered slash prefixes.
- callbacks/subscriptions match segment-list and rendered string glob patterns.
- TypeScript and Elixir fixtures agree.

Migration tests:

- old `a.b.c` becomes segments `["a", "b", "c"]` and rendered `a/b/c`.
- migrated `store_entries`, `store_ops`, and snapshots agree.
- collision preflight aborts before writing.
- migration is idempotent or refuses already-migrated stores clearly.

## Guardrails

After this work starts, production code should not:

- call `String.split(path, ".")`
- call `String.split(path, "/")` outside the path module
- join path segments with `Enum.join(..., ".")`
- build child paths with string interpolation
- treat REST URL segments as the authoritative path model
- accept slash-as-dot aliases in new APIs

The path module should be the only place that knows how paths are serialized.

## Open Decisions

1. **Wire shape.**
   Decide whether capver-next uses only `path_segments`, or includes both
   `path_segments` and rendered `path` during a transition. The clean model is
   `path_segments` authoritative and `path` rendered for compatibility/display.

2. **Literal wildcard glob matching.**
   Direct entry paths can contain `*` or `**`, but exact glob matching for
   literal wildcard-token segments needs a separate escaping rule if customers
   need it.

3. **Legacy compatibility duration.**
   Decide how long old dotted clients are allowed to connect after the server
   supports segment-first paths. The recommended answer is "only through the
   migration window."

4. **Import format versioning.**
   Exported data should probably include a path format version so future
   importers can distinguish legacy dotted exports from segment-first exports
   without guessing.

5. **Ecto prefix configuration.**
   Decide whether `prefix: "reading.links"` in the Ecto adapter means a single
   segment containing a dot or two segments. For the new model, prefer
   requiring segment-list prefixes, with rendered slash prefixes accepted as
   convenience.
