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
- 🔴 **`Dust.Cache.Ecto` config shape is a trap — and it only bites in prod.**
  The cache tuple's second element is dispatched by type in `SyncEngine.init/1`:
  a **list** → `cache_mod.start_link(opts)` (stateful caches like Memory); an
  **atom** → used directly as the `cache_target`. `Dust.Cache.Ecto` is stateless
  and its functions take the **Repo module** as that target
  (`read(repo, store, path)`), so the correct config is
  `{Dust.Cache.Ecto, MyApp.Repo}` — an atom. We wrote the natural-looking
  `{Dust.Cache.Ecto, repo: MyApp.Repo}` (a keyword list), which hits the
  `start_link` branch and crashes at boot with
  `UndefinedFunctionError: Dust.Cache.Ecto.start_link/1`. Worse, it's invisible
  until the cache actually starts: our dev keeps Dust disabled and tests use the
  Memory cache, so this only surfaced when we drove the real Ecto cache against
  the cloud (it would have crashed prod on the `DUST_ENABLED=true` flip). Asks:
  (1) accept `{Dust.Cache.Ecto, repo: MyRepo}` too (extract the repo) since the
  keyword form is what everyone will type; or (2) validate the cache tuple at
  init with a clear error ("Dust.Cache.Ecto expects the Repo module, e.g.
  `{Dust.Cache.Ecto, MyApp.Repo}`"); and (3) show the exact shape + the required
  `synced_at` migration in one "production setup with the Ecto cache" doc.

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

## Auth / permissions (first live connection)

- 🟡 **`:unauthorized` on lease/put after a successful connect+read is
  opaque.** Our first cloud trial connected, authenticated, and *joined* the
  store (read OK, catch-up complete), but `Dust.put` and `Dust.lease` both
  returned `{:error, :unauthorized}` — the token was read-only for the store.
  The error is correct, but: (1) there's no signal at *connect* time that the
  token is read-only, so it surfaces only on first write; (2) `single_flight`
  propagates the bare `{:error, :unauthorized}`, which reads like a code bug
  until you probe `put`/`lease` directly. Suggest: document token scopes
  (read vs read-write) and how to mint a write token; consider surfacing
  capability at join (`status.permissions`) so adopters fail fast with a clear
  message instead of debugging an opaque `:unauthorized` on the first lease.
- 🟢 **Resolved at 0.1.2 (`7639145`).** Re-minting the token read-write fixed
  the `:unauthorized`, and the capability-at-join suggestion *landed*:
  `Dust.status/1` now carries `permissions: %{read:, write:}`, `scopes`, and
  `store_access`. A connected read-write trial reports
  `permissions: %{read: true, write: true}` with `entries:write` in scopes.
  Exactly the fail-fast signal we wanted. 👍

## Acked-op replies never reach the SDK against the live cloud — ROOT-CAUSED & FIXED 🟢

**Resolution (fixed in `sdk/elixir`):** This was a real SDK race, not a server
or token problem. The server replies correctly — proven with a raw Slipstream
client (`await_reply/2`) that got `{:ok, %{"store_seq" => N}}` for a `set` and
`{:ok, %{"token" => N, "expires_at" => …}}` for a `lease`. The bug:

- The server does `broadcast!(… "event" …)` **before** sending the `phx_reply`
  ack. So the committed-echo (`{:server_event, …}`) cast reaches the SyncEngine
  **before** the ack (`{:write_accepted, …}`).
- `handle_cast({:server_event, …})` **deletes** `pending_ops[client_op_id]` as
  part of reconciliation. By the time `{:write_accepted, …}` runs, the pending
  op is gone, its `nil ->` branch did a **silent `{:noreply}`**, and the
  caller's `:from` was never answered → hang (acked `put/4` timed out at 5 s;
  `lease`/`single_flight` at `:infinity` hung forever).

**The fix (3 parts, all in `sdk/elixir`):**
1. **Answer from whichever signal lands first.** A shared `answer_waiter/2`
   replies to `:from` at-most-once (it pops `:from`); both `:server_event` and
   `:write_accepted` call it. `:server_event` builds the ack reply from the
   echo's canonical value + `store_seq` (`ack_reply_from_event/2`) — for a lease
   the echo value *is* the lease envelope, so it reconstructs `%Dust.Lease{}`.
2. **No silent swallow.** `handle_reply/3`'s `_ -> :ok` catch-all now logs a
   warning and routes the unrecognised reply through `handle_write_rejected`, so
   a blocked caller gets `{:error, :unexpected_reply}` instead of hanging.
3. **Hard backstop against any future lost reply.** Every acked op (one carrying
   `:from`) arms a `{:ack_timeout, client_op_id}` deadline (`@ack_timeout_ms`,
   30 s) in `send_to_connection/2`. If neither ack nor echo answered the caller
   by then, the engine replies `{:error, :timeout}` (logged loudly) and never
   hangs. This is what lets `lease`/`renew`/`release` keep their `:infinity`
   call safely — the engine *guarantees* a reply. Tagged tuples throughout, no
   try/catch, no silent vanish.

Regression tests added to `test/dust/sync_engine_test.exs` (echo-before-ack,
ack-before-echo no-double-reply, lease-answered-by-echo-only). Full SDK suite
green (243). Verified live against `wss://dustlayer.io`: acked `set`/`lease`
reply, `single_flight` dedupes, and a two-process cross-env run shows env B
riding env A's published result without re-running the work.

### Original report (kept for context)

The headline blocker for the live multi-env demo. With a confirmed
**read-write** token against `wss://dustlayer.io` (`james/rtsrc-fb`):

- **Writes commit server-side.** Fire-and-forget `Dust.put/3` returns `:ok`,
  the value reads back, `last_store_seq` advances across runs, and
  `entry_count` grows. A `lease` we issued even **persisted** —
  `Dust.get(store, "trial/lock")` returns
  `%{"_type" => "lease", "token" => 5, "holder" => nil, ...}`. So the server
  *processes and commits* both `set` and `lease` ops.
- **But every acked op times out / hangs.** `Dust.put/4` (acked) times out at
  its internal 5 s `GenServer.call`; `Dust.lease/3` and `Dust.single_flight/4`
  hang (lease calls with `:infinity`). The op commits server-side, but the
  caller's `from` is never replied to — the `phx_reply` isn't being delivered
  to / matched by the SDK.
- **Likely root cause.** `Dust.Connection.handle_reply/3` matches only
  `{:ok, map}` and `{:error, map}`, with a `_ -> :ok` catch-all. Slipstream's
  `reply()` type is `:ok | :error | {:ok, json} | {:error, json}` — so a bare
  `:ok`/`:error` reply (or any non-map payload) is **silently swallowed** and
  the acked caller hangs forever. Whether the deployed cloud is replying with
  a shape the SDK doesn't match, or not replying at all, this catch-all turns
  it into an indefinite hang rather than a surfaced error.
- **Two concrete asks for Dust:**
  1. **Never let an acked op hang.** `lease`/`renew`/`release` use
     `GenServer.call(..., :infinity)`; `single_flight` inherits that. A missing
     ack should fail with `{:error, :timeout}` (bounded call + a watchdog on
     the pending `from`), never wedge the caller. Today a silent reply-shape
     mismatch = a permanently stuck scrape worker.
  2. **Don't swallow unmatched replies.** Replace `_ -> :ok` with a logged
     fallthrough (and reply `{:error, :unexpected_reply}` to the pending
     `from`) so a shape mismatch is loud, not a hang.
- **rtsrc-side mitigation (ours to own regardless).** `ScrapeCoordinator`
  must bound the `single_flight` call (Task + `Task.yield/shutdown`, or a
  timeout opt if Dust adds one) and degrade to a direct local fetch on
  timeout — a hung Dust must never block the Apify scrape path. This is the
  "no Dust HTTP in any hotpath" guarantee extended to "no Dust *stall* in any
  hotpath."

## Summary for the Dust team

Nothing here was a blocker — the integration landed cleanly behind a feature
flag. The highest-value smoothing, in order: (1) a documented **callback event
contract**; (2) a **`Dust.Subscriber` store resolver** for env-configured
stores; (3) a **`Testing.seed_flight` helper** (or doc) for the JSON-leaf
convention; (4) a **"which SDK / production Ecto-cache setup" doc** covering
`Dust.Cache.Ecto`, `synced_at`, and the subscribe-and-project pattern end to
end. The primitives themselves (lease, `single_flight`, fast-fail-when-
disconnected) behaved exactly as specified.
