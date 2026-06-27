# xlabs port brief — Dust trial round 2

Date: 2026-05-11
Audience: the same agent that did the original trial in
`/Users/james/Desktop/elixir/xlabs-io-phx/docs/dust-trial-notes.md`.

## What this is

Round 1 of the Dust trial produced a sharp set of notes. Two rounds of
fixes followed. This brief points you at what changed, what's new, and
what to port — then asks you to do the same kind of trial again, with
notes in the same format.

The headline change since your trial: there is now an official
`dust_ecto` package that does what your `Xlabs.Dust.{Client,Schema,Repo}`
trio did by hand. The point of round 2 is to port the xlabs app from the
hand-rolled client to `dust_ecto` and tell us where it still hurts.

## What changed in Dust itself

Server side, things you flagged that got addressed:

- **DELETE actually works.** `DELETE /api/stores/:org/:store/entries/:path`
  is a first-class op now. Soft-delete via nil PUT is no longer needed.
- **HEAD works.** `HEAD /entries/:path` for cheap existence checks (S3-style).
  Returns `200` with the current revision in `ETag`, `404` if missing.
- **Slash + dot in paths.** Path segments accept dots when slash-escaped in
  the URL. `links."hello.world".title` → `entries/links/hello.world/title`
  on the wire. Encoding is RFC 3986 path-segment (spaces → `%20`, not `+`).
- **CAS via `If-Match`.** PUT/DELETE accept `If-Match: <revision>`; 412 on
  conflict. Leaf-only in this release; subtree CAS is deferred.
- **Batch writes.** `POST /entries/batch_write` with an `ops` list. All-or-
  nothing transactional. Per-op `if_match` honoured.
- **Several quieter fixes** around error response shapes and validation —
  no more silent 200s for malformed bodies, etc.

The store/auth shape is unchanged: one token per installation, store named
`org/name`.

## What `dust_ecto` is

A package that ships alongside the Elixir SDK and gives you:

- `use DustEcto.Schema, prefix: "links"` — like your `Xlabs.Dust.Schema`
  but with required-field declarations and an optional `mode:` for
  subscriptions.
- `DustEcto.Repo` — `all/1`, `get/2`, `get!/2`, `stream/1`, `exists?/2`,
  `insert/1`, `update/1`, `delete/1,2`, `delete_all/1`, `subscribe/2`,
  `unsubscribe/1`.
- Two transports auto-selected at call time:
  - **HTTP** (Req, stateless) — for release tasks, scripts, anything
    without a supervisor. This is what xlabs uses today.
  - **SDK** (delegates to `Dust.Supervisor` if running) — same Repo API,
    but writes are local-first and subscriptions are realtime over WS.
  - The choice is made per call from `DustEcto.Transport.pick/0`. You
    don't pick — you start a supervisor and the SDK transport is used;
    you don't, and the HTTP transport is used.

The whole package is in `/Users/james/Desktop/elixir/dust/sdk/elixir_ecto/`.
Browse `lib/dust_ecto/` for the surface. There is **no README yet** — one of
the things this trial is meant to surface is what a stranger needs in it.

## Migration map (xlabs-specific)

Your code today, mapped to `dust_ecto` today:

| Today (`Xlabs.Dust.*`) | New (`DustEcto.*`) | Notes |
|---|---|---|
| `Xlabs.Dust.Client` | (delete entirely) | `DustEcto.Transport.HTTP` replaces it |
| `Xlabs.Dust.Schema` | `DustEcto.Schema` | Same shape: `use DustEcto.Schema, prefix: "links"`. Add `required: [:title, :url]` to opt into the required-fields guard. |
| `Xlabs.Dust.Repo.all/1` | `DustEcto.Repo.all/1` | Same name + return shape. |
| `Xlabs.Dust.Repo.get/2` | `DustEcto.Repo.get/2` | Same. |
| `Xlabs.Dust.Repo.insert/1` | `DustEcto.Repo.insert/1` | Same. |
| `Xlabs.Dust.Repo.update/1` | `DustEcto.Repo.update/1` | Same. |
| `Xlabs.Dust.Repo.soft_delete/2` | `DustEcto.Repo.delete/2` | Real delete now. Drop the soft-delete workaround. |

Concrete migration steps:

1. **Add the dep.** In `mix.exs`:
   ```elixir
   {:dust_ecto, path: "../dust/sdk/elixir_ecto"}
   ```
   (or `git:` when published.)
2. **Config rename.** `:xlabs, Xlabs.Dust` becomes `:dust_ecto`:
   ```elixir
   config :dust_ecto,
     store: System.get_env("DUST_STORE") || "xlabs/main",
     base_url: System.get_env("DUST_BASE_URL") || "https://dustlayer.io",
     token: System.get_env("DUST_TOKEN")
   ```
3. **Schema swap.** Replace `use Xlabs.Dust.Schema, prefix: "links"` with
   `use DustEcto.Schema, prefix: "links", required: [:title, :url]`.
4. **Repo swap.** Change `alias Xlabs.Dust.Repo` to `alias DustEcto.Repo`
   in `lib/xlabs/reading.ex`.
5. **Delete the three hand-rolled files** under `lib/xlabs/dust/` once the
   port compiles.
6. **Drop `soft_delete`.** `delete_link/1` becomes
   `DustEcto.Repo.delete(Link, slug)`.

Expect this whole port to take well under an hour. The point is *not* the
port — it's noticing where the new API still has bad ergonomics, where
docs are missing, and what would have made round 1 painless.

## What you couldn't do before, that you now can

Try at least one of these in the ported app:

- **`exists?/2`** before `add_link` to detect duplicate slugs without a
  full GET.
- **`subscribe/2`** with a `Link` schema — open a LiveView, write from
  the MCP server / curl, watch the page update. This is the headline
  Dust feature; round 1 didn't get to exercise it.
- **`batch_write` / `delete_all/1`** for the "wipe and reseed" admin
  flow, if you have one.
- **CAS** — pass `if_match:` to a `Repo.update/1` call and force a
  conflict by running two updates concurrently. Confirm the loser gets
  a `:conflict` `%DustEcto.Error{}` and not a silent stomp.

## Known rough spots (don't bother reporting these, we know)

- No published Hex release yet — path dep only.
- No README, no docs site for `dust_ecto`. (One of the trial outputs we
  want is "what should be in the README".)
- Subscribe is only available when the SDK supervisor is running. The
  HTTP transport returns `{:error, %DustEcto.Error{kind: :not_supported}}`.
  This is documented in `lib/dust_ecto/transport/http.ex` but probably
  not loud enough.
- Multi-store is single-token-per-installation by design for v1, but
  the architecture supports per-call store override (third arg shape is
  there but unused). Don't try to use it yet.

## How to take notes

Same format as round 1: `dust-trial-notes-r2.md` in `xlabs-io-phx/docs/`,
with `Good / Bad-unclear / Ugly` headers under each area. Areas to cover
this time:

- **Install & config** — was the dep declaration obvious? Did the config
  rename trip you up? Did anything fail silently when a config key was
  missing?
- **Schema migration** — did `required:` feel natural? Did `mode:` make
  any sense without docs?
- **Repo migration** — did `delete` "just work"? Any surprises in
  error shapes (`%DustEcto.Error{}` vs the old `{:error, {:http, ...}}`)?
- **Subscribe** — most important. Did you find it? Did the events
  arrive in the shape you expected? Did the required-fields guard
  silently drop anything you wanted to see?
- **New capabilities** — `exists?`, `batch_write`, CAS — did you discover
  these on your own, or only because this brief told you about them?
- **The missing README** — what *should* be in it? What did you have to
  read source to learn?

When you're done, commit the notes and tell James. We'll do the round-3
review the same way we did rounds 1 and 2 — pull each finding, verify
against code, fix with a regression test.

## Reference files (read these first)

In `/Users/james/Desktop/elixir/dust/sdk/elixir_ecto/`:

- `lib/dust_ecto/schema.ex` — `use` macro + introspection callbacks
- `lib/dust_ecto/repo.ex` — the full Repo surface
- `lib/dust_ecto/transport.ex` — `pick/0` selector + behaviour
- `lib/dust_ecto/transport/http.ex` — HTTP transport (this is what xlabs
  will end up using)
- `test/dust_ecto/repo_subscribe_test.exs` — the closest thing to a usage
  example for `subscribe/2`

The design doc at `/Users/james/Desktop/elixir/dust/docs/plans/2026-05-10-dust-ecto-design.md`
has the longer rationale if you need it, but the brief above plus the code
should be enough.
