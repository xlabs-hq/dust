# Prefix-scoped subscription — design note

**Status:** open design question, no implementation planned yet.
**Origin:** xlabs feedback ("whole store in memory"), corrected after
tracing what dust_ecto + `Dust.Cache.Ecto` actually does.

## The actual gap

The original feedback was framed as RAM pressure. Tracing the xlabs path
(dust_ecto → `Dust.SyncEngine` → `Dust.Cache.Ecto` → Postgres) shows
that's not what happens in production:

- `Dust.Cache.Ecto` (`sdk/elixir/lib/dust/cache/ecto.ex`) is
  straight-through SQL. Every `read`/`read_entry`/`read_many`/`read_all`
  is an Ecto query against a `CacheEntry` table in the consumer's Repo.
  No in-memory mirror; steady-state RAM is just the working set of
  outstanding queries.
- The only RAM-resident transient is the snapshot frame at connection
  time. `sync_engine.ex:527` receives the whole snapshot in one cast,
  iterates over it writing entries to the cache, then drops the
  reference. Peak transient ≈ snapshot payload size, freed at end of
  the cast.
- `Dust.Cache.Memory` *does* hold everything in a GenServer heap — but
  it's the dev/test default, not what a production dust_ecto consumer
  picks.

What's actually true, restated:

> The wire protocol delivers a per-store snapshot, then catch_up. There
> is no prefix-scoped subscription mode at the protocol or SDK level. A
> consumer that names `stores: ["acme/big-store"]` pays for **the whole
> store's snapshot bytes over the wire on every connect**, and **a full
> `CacheEntry` row count in their Postgres**, regardless of which
> subtrees they actually read.

Confirmed in `server/lib/dust/sync/connection.ex:143` (server-side
snapshot send) and `sdk/elixir/lib/dust/sync_engine.ex:527`
(client-side snapshot apply).

## Why this matters (and where it doesn't)

**Doesn't matter for xlabs today.** xlabs follows the "store is the
unit of subscription" pattern — `james/xlabs-site` is per-site, holds
reading/drafting/tags/site-settings, a few KB total. Snapshot transfer
is noise; row count in Postgres is trivial.

**Would matter for:**

- A multi-tenant SaaS that wanted *one* big store across all customers
  (e.g. `acme/all-things`) but where each connected consumer only cares
  about their slice. Snapshot would balloon linearly with tenants.
- Any case where a logical store outgrows the budget — large numbers of
  records that organizationally belong together but no individual
  consumer reads all of.

The defensible answer for these cases today is "make a smaller store."
That works until store boundaries start being driven by sync-cost
considerations rather than by organizational meaning (one webhook URL,
one ACL, one logical thing) — at which point the abstraction is
leaking.

## Proposed shape

A subscription filter on the WS protocol:

```elixir
stores: [%{name: "acme/all-things", paths: ["tenants/123/**"]}]
```

Server changes:

- Snapshot phase respects the filter — only entries whose path matches
  one of the supplied globs get sent.
- Catch-up phase filters ops by path against the same globs.
- Live phase already filters ops per-subscription; same filter applies.

SDK changes (per language):

- The cache schema needs to record what the active subscription scope
  is, so subsequent connects can re-snapshot only the same scope (or
  detect a scope widening and re-snapshot fully).
- Every read API has to understand: "the cache holds *only* paths
  matching these globs; reads outside that scope are misses by
  construction, not by absence." A `get` on an out-of-scope path
  shouldn't silently return `nil` as if the key didn't exist — it
  should distinguish "not in scope" from "scope-internal miss."
- The `Dust.Cache.Ecto` table's `CacheEntry` rows for the in-scope
  subtrees only; nothing else gets written.

## Non-trivial parts

1. **Cache-schema parity.** Whatever lands has to roll across all four
   SDKs (Elixir, dust_ecto, TypeScript, plus Ruby/Python when they
   exist) in lockstep. Adding a `scope` column to `CacheEntry` is the
   easy half; adapting every read API to honor it is the rest.

2. **Scope changes mid-life.** If a consumer changes the `paths`
   filter, the cache needs to know whether to grow (re-snapshot the
   new portion) or shrink (delete rows outside the new scope). Likely
   the SDK should require an explicit scope version that, when bumped,
   triggers a full re-snapshot for safety.

3. **Out-of-scope reads.** Today, `get(store, path)` where the key
   doesn't exist returns `{:error, :not_found}`. Once subscriptions
   are scoped, the same return shape is now ambiguous — "doesn't exist
   in the store" vs. "exists but not subscribed." A distinct
   `:out_of_scope` error is the honest answer, but it forces every
   caller to handle a new failure mode. Could also be opt-in via an
   option, with the default being permissive (treat as miss) for
   migration ease.

4. **Watcher overlap.** `Dust.on/4` takes a pattern. If the subscription
   scope is `["tenants/123/**"]` but the user calls
   `Dust.on(store, "tenants/*/billing/**", cb)`, the watcher should
   probably error rather than silently never firing. Watchers must be
   subset-of scope.

5. **Subtree reads (`enum`, `range`, `read_subtree`).** Already
   pattern-driven, so most of the work is "is your read pattern a
   subset of your subscription pattern?" If not, surface that.

## Suggested next step

Not "let's build it." More like: file as a known design boundary,
revisit when there's a concrete consumer asking for it. The xlabs case
doesn't justify the work today. A multi-tenant SaaS on dust would.

If/when revisited: write a real implementation plan covering the four
non-trivial parts above, and decide which SDK to prototype in first
(probably Elixir — fastest iteration loop, then port to dust_ecto for
the Postgres-cache contract, then TypeScript).

## Companion finding

While tracing this, also confirmed: `Dust` (Elixir SDK) had no
`cloud_url/0` helper. Every consumer wanting to hit dustlayer.io
reinvented `wss://dustlayer.io/ws/sync`. Fixed in the same session —
`Dust.cloud_url/0` now exists; docs updated. Not related to the
prefix-subscription question but discovered alongside it.
