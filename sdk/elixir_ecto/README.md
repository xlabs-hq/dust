# DustEcto

Ecto-shaped facade over [Dust][dust]. Use `Ecto.Schema`,
`Ecto.Changeset`, and a Repo-like module to talk to a Dust store from
Phoenix apps without writing a custom HTTP client.

```elixir
defmodule MyApp.Reading.Link do
  use DustEcto.Schema,
    prefix: "links",
    required: [:slug, :title, :url]

  embedded_schema do
    field :title, :string
    field :url, :string
    field :note, :string
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:slug, :title, :url, :note])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end

{:ok, link} =
  %MyApp.Reading.Link{}
  |> MyApp.Reading.Link.changeset(%{slug: "dust", title: "Dust", url: "https://dustlayer.io"})
  |> DustEcto.Repo.insert()

{:ok, [%MyApp.Reading.Link{} | _]} = DustEcto.Repo.all(MyApp.Reading.Link)
```

`DustEcto.Repo` is **not** an `Ecto.Repo`. It's a deliberately small
surface that maps cleanly onto Dust's KV model. The parts that don't
map (`where`, `from`, `preload`, `transaction`) aren't there. See
[Limitations](#limitations).

[dust]: https://dustlayer.io

---

## Quick start

```elixir
# mix.exs
def deps do
  [
    {:dust_ecto, "~> 0.1"}
  ]
end
```

```elixir
# config/runtime.exs
config :dust_ecto,
  store: System.get_env("DUST_STORE") || "myorg/mystore",
  base_url: System.get_env("DUST_BASE_URL") || "https://dustlayer.io",
  token: System.fetch_env!("DUST_TOKEN")
```

```elixir
# lib/my_app/reading/link.ex
defmodule MyApp.Reading.Link do
  use DustEcto.Schema, prefix: "links", required: [:slug, :title]

  embedded_schema do
    field :title, :string
    field :note, :string
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:slug, :title, :note])
    |> validate_required(__dust_required_fields__())
    |> validate_dust_slug(:slug)
  end
end
```

```elixir
# in IEx or a context module
alias DustEcto.Repo
alias MyApp.Reading.Link

%Link{} |> Link.changeset(%{slug: "hello", title: "Hello"}) |> Repo.insert()
{:ok, [link]} = Repo.all(Link)
Repo.delete(Link, "hello")
```

That's a working installation against the deployed dustlayer.io. No
supervision tree, no migrations. **Realtime subscriptions need extra
setup** — see [Subscribe](#subscribe).

---

## Storage modes — `:flat` (default) vs `:map`

The single most important configuration choice. Pick `:flat` unless
you know you want `:map`.

| | `:flat` (default) | `:map` |
|---|---|---|
| Wire shape | N leaves at `<prefix>.<slug>.<field>` | One value at `<prefix>.<slug>` |
| Writes per record | N PUTs | 1 PUT |
| Atomic? | No (partial state observable mid-write) | Yes (one revision per record) |
| Multi-writer composability | Yes — other clients edit one field without knowing the rest | No — any external write to a field races a `:map` write that clobbers the whole record |
| CAS granularity | Per leaf (use `batch_write/1`) | Per record (use `:if_match` on `update/2`) |

Storage diagram for a record `MyApp.Reading.Link{slug: "foo", title: "Foo", url: "https://foo"}`:

```
:flat (default)             :map
─────────────────           ─────────────────
links.foo.title  "Foo"      links.foo  {title: "Foo",
links.foo.url    "..."                  url: "..."}
```

**When to pick `:flat`:**
- Multiple writers may edit the same record (MCP server, curl, sibling
  Phoenix nodes, a CLI tool).
- You want per-field subscriptions and granular revision tracking.
- You're storing data that's naturally key-per-field anyway.

**When to pick `:map`:**
- Your Phoenix app is the only writer for these records.
- You need whole-record atomicity on every write.
- You want a single revision per record for simple CAS.

Reads work identically in both modes. `Repo.get/2` GETs the slug path
and the server returns the assembled value either way.

---

## Transport detection

Two transports ship: `DustEcto.Transport.SDK` (recommended; uses
`Dust.Supervisor` for realtime + local cache) and
`DustEcto.Transport.HTTP` (Req-based, stateless, no realtime).

`DustEcto.Transport.pick/0` runs on every Repo call. Selection order:

1. Explicit `config :dust_ecto, :dust_facade, MyApp.Dust` → SDK mode.
2. `Dust.SyncEngineRegistry` has the configured store running → SDK
   mode using the global `Dust` facade.
3. Otherwise → HTTP mode.

To verify which transport is active:

```elixir
{transport, _config} = DustEcto.Transport.pick()
# => {DustEcto.Transport.HTTP, %{...}} | {DustEcto.Transport.SDK, %{...}}
```

The check is cheap (one or two ETS lookups), so starting
`Dust.Supervisor` at runtime promotes you from HTTP to SDK with no
code change.

---

## Repo surface

```
all/1            stream/1        get/2           get!/2
exists?/2        insert/1        update/1,2      delete/1,2,3
delete_all/1     batch_write/1   subscribe/2     subscribe_raw/2
unsubscribe/1
```

All write functions return `{:ok, struct} | {:error, %Ecto.Changeset{}
| %DustEcto.Error{}}`. Reads return `{:ok, term} | {:error, :not_found
| %DustEcto.Error{}}`.

---

## Error handling

All transport-level failures land as `%DustEcto.Error{kind, detail,
retryable?}`. Pattern-match on `:kind` to decide what to do:

```elixir
case Repo.insert(cs) do
  {:ok, struct} -> ...
  {:error, %Ecto.Changeset{} = cs} -> # validation failed
  {:error, %DustEcto.Error{kind: :conflict}} -> # CAS lost the race
  {:error, %DustEcto.Error{kind: :rate_limited, detail: %{retry_after: s}}} ->
    # back off s seconds and retry
  {:error, %DustEcto.Error{kind: :not_implemented}} ->
    # deployed server doesn't expose this op — likely a deploy lag
  {:error, %DustEcto.Error{retryable?: true}} -> # transient — retry
  {:error, %DustEcto.Error{}} -> # bail
end
```

| `kind` | When you'll see it |
|---|---|
| `:network` | Req call failed before reaching the server (DNS, TLS, refused). Retryable. |
| `:http` | Unrecognized non-2xx status. 5xx is retryable, 4xx isn't. |
| `:conflict` | `If-Match` precondition failed. `detail` has `current_revision`. |
| `:not_supported` | Feature unavailable on the active transport (e.g. `subscribe` in HTTP mode). |
| `:not_implemented` | Server returned 404 on a whole route — the deployed server is older than dust_ecto expects. |
| `:nothing_to_write` | `insert`/`update` had no fields to send. Usually a bug in the caller's changeset. |
| `:timeout` | SDK write didn't get an ack in time. Don't blind-retry; the write may still land. |
| `:unauthorized` | Token rejected. |
| `:invalid_params` | Server rejected the request shape (other than 404). |
| `:rate_limited` | 429. `detail.retry_after` carries the header. Retryable. |

---

## CAS — `:if_match`

Optimistic concurrency on writes. The server enforces leaf-only CAS,
so the semantics depend on storage mode:

**`:map` mode** — single PUT, single revision per record:

```elixir
{:ok, entry} = DustEcto.Transport.HTTP.get(store, "links.foo")
# entry.revision is the current server revision

cs = Link.changeset(link, %{title: "new"})

case Repo.update(cs, if_match: entry.revision) do
  {:ok, _} -> :saved
  {:error, %DustEcto.Error{kind: :conflict}} -> :reload_and_retry
end
```

**`:map` mode delete:**

```elixir
Repo.delete(Link, "foo", if_match: 7)
# or
Repo.delete(%Link{slug: "foo"}, if_match: 7)
```

**`:flat` mode:** `update/2` with `if_match:` *raises* — there's no
single revision to compare against. For atomic multi-field CAS in
`:flat` mode, use `batch_write/1`:

```elixir
Repo.batch_write([
  {:update, link1_cs, if_match: 5},
  {:update, link2_cs, if_match: 9}
])
# committed atomically server-side; if any if_match fails, none lands
```

---

## Atomic multi-record writes — `batch_write/1`

```elixir
Repo.batch_write([
  {:insert, Link.changeset(%Link{}, attrs1)},
  {:insert, Link.changeset(%Link{}, attrs2)},
  {:update, existing_link_cs, if_match: 7},
  {:delete, Link, "stale-slug"},
  {:delete, Link, "old", if_match: 4}
])
```

Validates each changeset short-circuit-style — if any fails,
`{:error, %Ecto.Changeset{}}` and nothing is sent. Otherwise the
whole batch commits atomically server-side.

In `:flat` mode, each insert/update expands to N wire ops (one per
non-nil field). `:if_match` on a `:flat` op raises — per-field CAS
needs per-field revisions, which v1 doesn't surface.

---

## Subscribe

Realtime subscriptions are **only available when the SDK transport is
active** — i.e. `Dust.Supervisor` is in your supervision tree. From
HTTP mode, `Repo.subscribe/2` returns `{:error, %DustEcto.Error{kind:
:not_supported}}`.

### Setting up the SDK supervisor

```elixir
# lib/my_app/dust.ex
defmodule MyApp.Dust do
  use Dust, otp_app: :my_app
end
```

```elixir
# config/runtime.exs
config :my_app, MyApp.Dust,
  stores: ["myorg/mystore"],
  repo: MyApp.Repo

config :dust_ecto, :dust_facade, MyApp.Dust
```

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyApp.Dust,           # ← add this
  MyAppWeb.Endpoint
]
```

### Recommended: `Phoenix.PubSub` bridge

If you're in a Phoenix app, **use the PubSub bridge** — one line in
`mount/3`, no callback discipline to remember, automatic cleanup:

```elixir
defmodule MyAppWeb.LinksLive do
  use MyAppWeb, :live_view
  alias MyApp.Reading.Link

  def mount(_, _, socket) do
    if connected?(socket) do
      :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, MyApp.PubSub, "links")
    end

    {:ok, assign(socket, links: load_links())}
  end

  def handle_info({:dust_event, {:upserted, %Link{} = link}}, socket),
    do: {:noreply, update(socket, :links, &upsert_by_slug(&1, link))}

  def handle_info({:dust_event, {:deleted, slug}}, socket),
    do: {:noreply, update(socket, :links, &delete_by_slug(&1, slug))}
end
```

Add `{:phoenix_pubsub, "~> 2.0"}` to your deps (most Phoenix projects
already have it). No `terminate/2` cleanup — `Phoenix.PubSub` monitors
subscribers and unsubscribes automatically. The bridge starts one
shared broadcaster per topic so 100 LiveViews subscribed to `"links"`
cost one Dust subscription, not 100.

### Raw `Repo.subscribe/2`

If you can't use Phoenix.PubSub (release script, non-Phoenix app,
custom fan-out), drop down to `Repo.subscribe/2` directly:

```elixir
{:ok, ref} =
  DustEcto.Repo.subscribe(Link, fn
    {:upserted, %Link{} = link} -> handle_upsert(link)
    {:deleted, slug} -> handle_delete(slug)
  end)

# later
DustEcto.Repo.unsubscribe(ref)
```

The callback runs **inside the SDK's per-store sync engine process**.
If it blocks, every subscriber on that store waits. The standard safe
pattern is to send a message and return immediately:

```elixir
pid = self()

{:ok, _ref} =
  DustEcto.Repo.subscribe(Link, fn event ->
    send(pid, {:link, event})
    :ok
  end)
```

If `pid` dies without unsubscribing, the SDK registry keeps the
callback and `send/2`s into a dead pid for every subsequent write.
Track the ref and `Repo.unsubscribe/1` it on shutdown. This is exactly
the bookkeeping the PubSub bridge eliminates.

`subscribe_raw/2` is the lower-level escape hatch — callback receives
the raw event map `%{op:, path:, value:, store_seq:, ...}` instead of
the assembled struct. Useful for provenance or custom assembly.

---

## Migrating from a hand-rolled client

If you've already built a thin wrapper around the Dust HTTP API
(`Client`, `Schema`, `Repo` modules of your own), the mapping is
mechanical:

| Hand-rolled | DustEcto |
|---|---|
| `MyApp.Dust.Client` | Delete entirely — `DustEcto.Transport.HTTP` replaces it. |
| `use MyApp.Dust.Schema, prefix: "foo"` | `use DustEcto.Schema, prefix: "foo", required: [...]` |
| `MyApp.Dust.Repo.all/get/insert/update` | `DustEcto.Repo.all/get/insert/update` (1-for-1) |
| `MyApp.Dust.Repo.soft_delete` (null-PUT workaround) | `DustEcto.Repo.delete/2` (real delete; needs Dust server ≥ 0.1) |
| `{:error, {:http, status, body}}` tuples | `{:error, %DustEcto.Error{}}` — pattern-match on `:kind` |

Config rename: whatever app key you used (`:my_app, MyApp.Dust`)
becomes `:dust_ecto` directly.

---

## Limitations

| Not supported | Why / workaround |
|---|---|
| `Ecto.Query` (`where`, `from`, `join`, `preload`) | Dust is KV, not relational. Filter in Elixir after `Repo.all/1`, or use a prefix-shaped key design. |
| `insert_all/2` | Use `batch_write/1` with a list of `{:insert, cs}` ops. |
| `transaction/1` | Use `batch_write/1` for atomic multi-record commits. |
| `Repo.insert/1` insert-or-fail semantics | Dust writes are upserts. If you need fail-on-duplicate, `Repo.exists?/2` first and accept that another writer can race you. |
| Per-field CAS in `:flat` mode `update/2` | Use `batch_write/1` with per-op `:if_match`. |

---

## Environment variables

Config keys (under `:dust_ecto`):

| Key | Default | Where to get it |
|---|---|---|
| `:store` | *required* | The Dust store name as `org/name`. |
| `:base_url` | `https://dustlayer.io` | Override only for self-hosted Dust or a staging instance. |
| `:token` | *required* | The store API token. Create one at the [Dust dashboard](https://dustlayer.io). |

Typical `runtime.exs` reads these from env:

```elixir
config :dust_ecto,
  store: System.fetch_env!("DUST_STORE"),
  base_url: System.get_env("DUST_BASE_URL") || "https://dustlayer.io",
  token: System.fetch_env!("DUST_TOKEN")
```

Config changes need a server restart in dev — Phoenix's code reload
doesn't reread `Application.put_env` from `.env` files.

---

## Server compatibility

| dust_ecto | Required dust server |
|---|---|
| `0.1.x` | `0.1.x` (DELETE and `batch_write` routes). Older servers will surface `%DustEcto.Error{kind: :not_implemented}` on those calls. |

The deployed instance at `dustlayer.io` tracks the latest released
server. If you self-host, mind the matrix.

---

## License

MIT.
