# rtsrc → Dust Integration Friction Log

**Date:** 2026-06-27 (living doc — appended during the rtsrc integration)
**Source:** rtsrc adopter, integrating `dustlayer` @ `1d77b19`
**Purpose:** Capture every rough edge (API, ergonomics, docs) hit while
wiring `Dust.single_flight` + `Dust.Cache.Ecto` into a real Phoenix app,
so the Dust team can smooth the next adopter's path.

Legend: 🟢 worked well · 🟡 minor friction · 🔴 blocker/needs doc.

## Setup & deps

- 🟡 **Two Elixir SDKs, no signpost.** `dustlayer` (full SDK, `Dust.*`,
  local-cache reads) vs `dustlayer_ecto` (HTTP facade, `DustEcto.*`). An
  adopter wanting hotpath-safe reads must pick `dustlayer` + the
  `Dust.Cache.Ecto` backend — but nothing in either README says "use this
  one for X." A one-paragraph "which package?" signpost would save a wrong
  turn. (We picked right only because we read the source.)
- 🟡 **Git/sparse install works but is undocumented.** Consuming pre-Hex
  via `{:dustlayer, git: "…", ref: "…", sparse: "sdk/elixir"}` is fine, but
  the `sparse: "sdk/elixir"` bit (SDK lives in a subdir of the monorepo) is
  non-obvious. Worth a README "installing from source" note until Hex.
- 🟢 **Optional-dep activation is clean.** `Dust.Cache.Ecto` lit up purely
  because the host app already has `ecto_sql`; no extra wiring to "turn on"
  the Ecto backend. Good.

## Config & startup

- 🟡 **No documented "inert until configured" / graceful-no-server mode for
  prod.** `testing: :manual` exists but is test-flavored. An adopter rolling
  out gradually wants to add the supervision child yet keep it dormant
  (no crash-loop) until a server URL + token are provisioned. We worked
  around it by gating the child behind our own config flag; a first-class
  `enabled: false` (start supervised but don't connect) would be cleaner.
  *(To confirm as we wire it.)*
- 🟡 **`Dust.Cache.Ecto` required opts under-shown.** The `Dust.Instance`
  moduledoc only demonstrates `{Dust.Cache.Memory, []}`. The Ecto backend's
  `{Dust.Cache.Ecto, repo: MyApp.Repo}` shape + the required `synced_at`
  migration aren't in one "production setup with the Ecto cache" place.

## Testing

- 🟢 **`Dust.Testing` is the right shape.** `seed/2`, `emit/3` (fires an
  event synchronously through the subscriber pipeline), and status control
  let us unit-test a projection subscriber with **no live server**. This is
  exactly what an adopter needs. Worth featuring prominently in docs — it's
  currently easy to miss.

## Docs

- 🔴 **Subscribe section appears thin/missing.** Both READMEs say "Realtime
  subscriptions need extra setup — see Subscribe," but the Subscribe section
  is hard to find / sparse. The declarative `Dust.Subscriber` (`use
  Dust.Subscriber, store:, pattern:` + `subscribers:` config) is the key
  mechanism for the Ecto-cache adopter and deserves a worked example
  (subscribe → project into a typed table).

## Subscriptions / projection (building the materializer)

- 🟡 **`Dust.Subscriber` binds the store at compile time.** `use
  Dust.Subscriber, store: "...", pattern: "..."` bakes the store name, but
  our store is **runtime/env-configured** (prod+staging share one store via
  `DUST_FB_STORE`; dev/test differ). So we couldn't use the declarative
  subscriber + `subscribers:` config — we fell back to a plain GenServer
  calling `Dust.on(store, pattern, &project/1, mode: :committed)` on boot.
  Suggest: let `Dust.Subscriber` accept a `{:from_config, otp_app, key}` or a
  0-arity resolver for the store, so env-configured stores can still use the
  blessed path.
- 🟡 **Callback event shape is undocumented.** Subscriptions deliver
  atom-keyed maps `%{store:, path:, op: :set|:delete|:put_file, value:,
  committed:, was_own:, source:, store_seq:, client_op_id:, ...}`. We learned
  this by reading `sync_engine.ex` (`dispatch_callbacks`). A documented
  "event contract" (keys + types + which `mode:` sees what) is needed — it's
  the core thing a subscriber author codes against.
- 🟡 **`single_flight` results arrive as a JSON *string* in `value`.**
  `single_flight` publishes `Jason.encode!(value)` as a scalar leaf (so the
  plain-map flattener doesn't shred a pointer into a subtree), so a subscriber
  projecting that key must `Jason.decode!` the `value`. Sensible, but
  implicit — worth a one-liner in the `single_flight` docs: "the published
  value is a JSON-encoded scalar; readers/subscribers decode it." Mirrors
  what `SingleFlight.last_value/2` already does internally.
- 🟢 **`mode: :committed` is the right default for a projection** — it
  includes the echo of our own writes, so a node that *is* the single_flight
  winner still materializes its own result through the same path. Good that
  this mode exists.

## single_flight wiring (the seam + scraper)

- 🟢 **Lease fails fast with `{:error, :unavailable}` when disconnected**
  (status precheck, `sync_engine.ex:296`). This makes the
  `on_unavailable: :run_local` degrade clean and, crucially, **testable in
  `:manual` mode without a server** — the degraded path and the fast (seeded)
  path cover most of the seam's logic in plain unit tests. Big win for adopter
  confidence.
- 🟡 **Seeding a `single_flight`-readable value in tests is non-obvious.**
  `Dust.Testing.seed(store, %{path => value})` stores `value` with
  `detect_type/1`. But `single_flight`'s fast path (`last_value/2`) only reads
  a leaf when `is_binary(raw) and type != "lease"` — it Jason-decodes a
  *string*. So to seed a fixture the fast path will treat as fresh, you must
  seed the **JSON-encoded string** (`Jason.encode!(blob)`), not the map; seed
  a map and `single_flight` reports `:miss`. Suggest either a
  `Dust.Testing.seed_flight/3` helper that encodes the way `single_flight`
  publishes, or a doc note. (Cost us one confused test run.)
- 🟢 **`{:publish, value}` / `{:abort, reason}` maps perfectly onto our
  domain.** "Apify run finished (even with zero posts)" → `{:publish}` (so the
  freshness window holds and nobody re-polls for an hour); "Apify errored
  (quota/network/run-failed)" → `{:abort}` (release the lease, retry next
  cycle). The definitive-vs-transient distinction is exactly the right knob.
- 🟢 **`Flight.coordinated?` is the signal we surface to telemetry.** We thread
  it into the scrape result so we can see when a fetch ran on the degraded
  (uncoordinated) path — i.e. when idempotency actually mattered. Nice that
  the SDK hands this back explicitly.

## Summary for the Dust team

Nothing here was a blocker — the integration landed cleanly behind a feature
flag. The highest-value smoothing, in order: (1) a documented **callback event
contract**; (2) a **`Dust.Subscriber` store resolver** for env-configured
stores; (3) a **`Testing.seed_flight` helper** (or doc) for the JSON-leaf
convention; (4) a **"which SDK / production Ecto-cache setup" doc** covering
`Dust.Cache.Ecto`, `synced_at`, and the subscribe-and-project pattern end to
end. The primitives themselves (lease, `single_flight`, fast-fail-when-
disconnected) behaved exactly as specified.
