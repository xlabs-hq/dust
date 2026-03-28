# Dust Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the Dust server, Elixir SDK, and protocol library — proving end-to-end sync with core operations (set, get, delete, merge).

**Architecture:** Monorepo with three Mix projects. Server is a Phoenix app following the [Phoenix Architecture Guide](../../../agents/PHOENIX_ARCHITECTURE_GUIDE.md). SDK is a library with pluggable cache adapters. Protocol library is shared between both. WebSocket sync via Phoenix Channels with MessagePack/JSON serializers. GenServer-per-store write serialization.

**Tech Stack:** Elixir 1.17+, OTP 27, Phoenix 1.7, Ecto 3.12, PostgreSQL 17+, Oban, WorkOS, let_me, Mint.WebSocket, Msgpax

**Reference docs:**
- Design: `docs/plans/2026-03-28-dust-phase1-design.md`
- Product spec: `docs/plans/2026-03-26-dust-design-v4.md`
- Phoenix patterns: `agents/PHOENIX_ARCHITECTURE_GUIDE.md`

---

## Task 1: Monorepo + Protocol Library Foundation

Set up the monorepo directory structure and the `dust_protocol` Elixir library with path parsing, glob matching, and op type definitions.

**Files:**
- Create: `protocol/elixir/mix.exs`
- Create: `protocol/elixir/lib/dust_protocol.ex`
- Create: `protocol/elixir/lib/dust_protocol/path.ex`
- Create: `protocol/elixir/lib/dust_protocol/glob.ex`
- Create: `protocol/elixir/lib/dust_protocol/op.ex`
- Create: `protocol/elixir/lib/dust_protocol/message.ex`
- Create: `protocol/elixir/lib/dust_protocol/codec.ex`
- Test: `protocol/elixir/test/dust_protocol/path_test.exs`
- Test: `protocol/elixir/test/dust_protocol/glob_test.exs`
- Test: `protocol/elixir/test/dust_protocol/op_test.exs`
- Test: `protocol/elixir/test/dust_protocol/codec_test.exs`
- Create: `protocol/spec/` (placeholder directories)

### Step 1: Create monorepo skeleton

```bash
mkdir -p protocol/spec protocol/elixir sdk/elixir cli
```

Create a root `.gitignore`:

```gitignore
# Elixir
_build/
deps/
*.beam
*.ez
.elixir_ls/

# Node
node_modules/
.vite/

# OS
.DS_Store
*.swp

# Env
.env
.env.*
!.env.example
```

### Step 2: Initialize protocol library

```bash
cd protocol/elixir && mix new dust_protocol && cd ../..
```

Update `protocol/elixir/mix.exs`:

```elixir
defmodule DustProtocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust_protocol,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:msgpax, "~> 2.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
```

### Step 3: Write failing tests for path parsing

`protocol/elixir/test/dust_protocol/path_test.exs`:

```elixir
defmodule DustProtocol.PathTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Path

  describe "parse/1" do
    test "parses dotted path into segments" do
      assert Path.parse("posts.hello.title") == {:ok, ["posts", "hello", "title"]}
    end

    test "parses single segment" do
      assert Path.parse("config") == {:ok, ["config"]}
    end

    test "rejects empty string" do
      assert Path.parse("") == {:error, :empty_path}
    end

    test "rejects path with empty segment" do
      assert Path.parse("posts..hello") == {:error, :empty_segment}
    end

    test "rejects path with leading dot" do
      assert Path.parse(".posts") == {:error, :empty_segment}
    end

    test "rejects path with trailing dot" do
      assert Path.parse("posts.") == {:error, :empty_segment}
    end
  end

  describe "to_string/1" do
    test "joins segments with dots" do
      assert Path.to_string(["posts", "hello", "title"]) == "posts.hello.title"
    end
  end

  describe "ancestor?/2" do
    test "parent is ancestor of child" do
      assert Path.ancestor?(["posts"], ["posts", "hello"])
    end

    test "grandparent is ancestor of grandchild" do
      assert Path.ancestor?(["posts"], ["posts", "hello", "title"])
    end

    test "path is not its own ancestor" do
      refute Path.ancestor?(["posts"], ["posts"])
    end

    test "child is not ancestor of parent" do
      refute Path.ancestor?(["posts", "hello"], ["posts"])
    end

    test "unrelated paths are not ancestors" do
      refute Path.ancestor?(["posts"], ["config"])
    end
  end

  describe "related?/2" do
    test "same path is related" do
      assert Path.related?(["posts"], ["posts"])
    end

    test "ancestor-descendant is related" do
      assert Path.related?(["posts"], ["posts", "hello"])
    end

    test "descendant-ancestor is related" do
      assert Path.related?(["posts", "hello"], ["posts"])
    end

    test "unrelated paths are not related" do
      refute Path.related?(["posts"], ["config"])
    end
  end
end
```

### Step 4: Run tests, verify they fail

```bash
cd protocol/elixir && mix test test/dust_protocol/path_test.exs
```

Expected: compilation errors — `DustProtocol.Path` does not exist.

### Step 5: Implement path module

`protocol/elixir/lib/dust_protocol/path.ex`:

```elixir
defmodule DustProtocol.Path do
  @doc "Parse a dotted path string into a list of segments."
  def parse(""), do: {:error, :empty_path}

  def parse(path) when is_binary(path) do
    segments = String.split(path, ".")

    if Enum.any?(segments, &(&1 == "")) do
      {:error, :empty_segment}
    else
      {:ok, segments}
    end
  end

  @doc "Join path segments into a dotted string."
  def to_string(segments) when is_list(segments) do
    Enum.join(segments, ".")
  end

  @doc "True if `a` is a strict ancestor of `b`."
  def ancestor?(a, b) when is_list(a) and is_list(b) do
    length(a) < length(b) and List.starts_with?(b, a)
  end

  @doc "True if paths are the same or one is an ancestor of the other."
  def related?(a, b) when is_list(a) and is_list(b) do
    a == b or ancestor?(a, b) or ancestor?(b, a)
  end
end
```

### Step 6: Run tests, verify they pass

```bash
cd protocol/elixir && mix test test/dust_protocol/path_test.exs
```

Expected: all pass.

### Step 7: Write failing tests for glob matching

`protocol/elixir/test/dust_protocol/glob_test.exs`:

```elixir
defmodule DustProtocol.GlobTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Glob

  describe "match?/2" do
    test "exact path matches" do
      assert Glob.match?("config.timeout", ["config", "timeout"])
    end

    test "exact path does not match different path" do
      refute Glob.match?("config.timeout", ["config", "retries"])
    end

    test "* matches one segment" do
      assert Glob.match?("posts.*", ["posts", "hello"])
    end

    test "* does not match zero segments" do
      refute Glob.match?("posts.*", ["posts"])
    end

    test "* does not match multiple segments" do
      refute Glob.match?("posts.*", ["posts", "hello", "title"])
    end

    test "** matches one segment" do
      assert Glob.match?("posts.**", ["posts", "hello"])
    end

    test "** matches multiple segments" do
      assert Glob.match?("posts.**", ["posts", "hello", "title"])
    end

    test "** matches deeply nested" do
      assert Glob.match?("posts.**", ["posts", "archive", "2024", "jan"])
    end

    test "** does not match zero segments" do
      refute Glob.match?("posts.**", ["posts"])
    end

    test "mixed pattern" do
      assert Glob.match?("users.*.settings", ["users", "alice", "settings"])
      refute Glob.match?("users.*.settings", ["users", "alice", "bob", "settings"])
    end

    test "** in middle of pattern" do
      assert Glob.match?("a.**.z", ["a", "b", "c", "z"])
      assert Glob.match?("a.**.z", ["a", "b", "z"])
      refute Glob.match?("a.**.z", ["a", "z"])
    end
  end

  describe "compile/1" do
    test "compiled pattern matches same as string pattern" do
      compiled = Glob.compile("posts.*")
      assert Glob.match?(compiled, ["posts", "hello"])
      refute Glob.match?(compiled, ["posts", "hello", "title"])
    end
  end
end
```

### Step 8: Run tests, verify they fail

```bash
cd protocol/elixir && mix test test/dust_protocol/glob_test.exs
```

### Step 9: Implement glob module

`protocol/elixir/lib/dust_protocol/glob.ex`:

```elixir
defmodule DustProtocol.Glob do
  @doc "Compile a glob pattern string into a structured form for repeated matching."
  def compile(pattern) when is_binary(pattern) do
    {:compiled, String.split(pattern, ".")}
  end

  @doc "Test whether a glob pattern matches a path (list of segments)."
  def match?(pattern, path) when is_binary(pattern) and is_list(path) do
    do_match(String.split(pattern, "."), path)
  end

  def match?({:compiled, pattern_segments}, path) when is_list(path) do
    do_match(pattern_segments, path)
  end

  defp do_match([], []), do: true
  defp do_match([], _), do: false
  defp do_match(_, []), do: false

  defp do_match(["**"], [_ | _]), do: true

  defp do_match(["**" | rest], [_ | path_rest] = path) do
    # ** matches one or more: try consuming current segment and continuing,
    # or skip past ** and match rest of pattern against current path
    do_match(["**" | rest], path_rest) or do_match(rest, path)
  end

  defp do_match(["*" | pattern_rest], [_ | path_rest]) do
    do_match(pattern_rest, path_rest)
  end

  defp do_match([segment | pattern_rest], [segment | path_rest]) do
    do_match(pattern_rest, path_rest)
  end

  defp do_match(_, _), do: false
end
```

### Step 10: Run tests, verify they pass

```bash
cd protocol/elixir && mix test test/dust_protocol/glob_test.exs
```

### Step 11: Write failing tests for op types

`protocol/elixir/test/dust_protocol/op_test.exs`:

```elixir
defmodule DustProtocol.OpTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Op

  describe "valid_op?/1" do
    test "accepts core ops" do
      assert Op.valid_op?(:set)
      assert Op.valid_op?(:delete)
      assert Op.valid_op?(:merge)
    end

    test "rejects unknown ops" do
      refute Op.valid_op?(:unknown)
    end
  end

  describe "new/1" do
    test "builds a set op" do
      op = Op.new(op: :set, path: "posts.hello", value: %{"title" => "Hello"}, device_id: "dev_1", client_op_id: "op_1")
      assert op.op == :set
      assert op.path == "posts.hello"
      assert op.value == %{"title" => "Hello"}
      assert op.device_id == "dev_1"
      assert op.client_op_id == "op_1"
    end

    test "builds a delete op with nil value" do
      op = Op.new(op: :delete, path: "posts.old", device_id: "dev_1", client_op_id: "op_2")
      assert op.op == :delete
      assert op.value == nil
    end
  end
end
```

### Step 12: Implement op module

`protocol/elixir/lib/dust_protocol/op.ex`:

```elixir
defmodule DustProtocol.Op do
  @enforce_keys [:op, :path, :device_id, :client_op_id]
  defstruct [:op, :path, :value, :device_id, :client_op_id]

  @core_ops [:set, :delete, :merge]

  def valid_op?(op), do: op in @core_ops

  def core_ops, do: @core_ops

  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
```

### Step 13: Run all tests, verify they pass

```bash
cd protocol/elixir && mix test
```

### Step 14: Write failing tests for codec (MessagePack + JSON)

`protocol/elixir/test/dust_protocol/codec_test.exs`:

```elixir
defmodule DustProtocol.CodecTest do
  use ExUnit.Case, async: true

  alias DustProtocol.Codec

  @hello %{type: "hello", capver: 1, device_id: "dev_1", token: "dust_tok_abc"}

  describe "msgpack" do
    test "round-trips a hello message" do
      {:ok, packed} = Codec.encode(:msgpack, @hello)
      assert is_binary(packed)
      {:ok, decoded} = Codec.decode(:msgpack, packed)
      assert decoded["type"] == "hello"
      assert decoded["capver"] == 1
    end
  end

  describe "json" do
    test "round-trips a hello message" do
      {:ok, encoded} = Codec.encode(:json, @hello)
      assert is_binary(encoded)
      {:ok, decoded} = Codec.decode(:json, encoded)
      assert decoded["type"] == "hello"
      assert decoded["capver"] == 1
    end
  end

  describe "event encoding" do
    test "encodes a canonical event" do
      event = %{
        type: "event",
        store: "james/blog",
        store_seq: 42,
        op: "set",
        path: "posts.hello",
        value: %{"title" => "Hello"},
        device_id: "dev_1",
        client_op_id: "op_1"
      }

      {:ok, packed} = Codec.encode(:msgpack, event)
      {:ok, decoded} = Codec.decode(:msgpack, packed)
      assert decoded["store_seq"] == 42
      assert decoded["op"] == "set"
    end
  end
end
```

### Step 15: Implement codec module

`protocol/elixir/lib/dust_protocol/codec.ex`:

```elixir
defmodule DustProtocol.Codec do
  @doc "Encode a map into the specified wire format."
  def encode(:msgpack, data) when is_map(data) do
    data
    |> stringify_keys()
    |> Msgpax.pack()
    |> case do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  def encode(:json, data) when is_map(data) do
    Jason.encode(data)
  end

  @doc "Decode binary data from the specified wire format."
  def decode(:msgpack, binary) when is_binary(binary) do
    Msgpax.unpack(binary)
  end

  def decode(:json, binary) when is_binary(binary) do
    Jason.decode(binary)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
```

### Step 16: Write the message module

`protocol/elixir/lib/dust_protocol/message.ex`:

```elixir
defmodule DustProtocol.Message do
  @doc "Build a hello message."
  def hello(capver, device_id, token) do
    %{type: "hello", capver: capver, device_id: device_id, token: token}
  end

  @doc "Build a hello response."
  def hello_response(capver_min, capver_max, your_capver, stores) do
    %{type: "hello_response", capver_min: capver_min, capver_max: capver_max,
      your_capver: your_capver, stores: stores}
  end

  @doc "Build a join message."
  def join(store, last_store_seq) do
    %{type: "join", store: store, last_store_seq: last_store_seq}
  end

  @doc "Build a write message."
  def write(store, op, path, value, device_id, client_op_id) do
    %{type: "write", store: store, op: to_string(op), path: path,
      value: value, device_id: device_id, client_op_id: client_op_id}
  end

  @doc "Build a canonical event."
  def event(store, store_seq, op, path, value, device_id, client_op_id) do
    %{type: "event", store: store, store_seq: store_seq, op: to_string(op),
      path: path, value: value, device_id: device_id, client_op_id: client_op_id}
  end

  @doc "Build an error message."
  def error(code, message) do
    %{type: "error", code: code, message: message}
  end
end
```

### Step 17: Write the top-level module

`protocol/elixir/lib/dust_protocol.ex`:

```elixir
defmodule DustProtocol do
  @moduledoc "Shared wire protocol types for Dust server and SDKs."

  @capver 1

  def capver, do: @capver
end
```

### Step 18: Run all protocol tests, verify green

```bash
cd protocol/elixir && mix test
```

### Step 19: Commit

```bash
git add protocol/ .gitignore
git commit -m "feat: add dust_protocol library with path parsing, glob matching, ops, and codec"
```

---

## Task 2: Server Scaffolding

Generate the Phoenix app and apply the architecture guide patterns: ports, UUIDv7, Tidewave, Bandit.

**Files:**
- Create: `server/` (generated by `mix phx.new`)
- Modify: `server/mix.exs`
- Modify: `server/config/config.exs`
- Modify: `server/config/dev.exs`
- Create: `server/lib/dust/schema.ex`
- Create: `server/priv/repo/migrations/*_enable_uuidv7.exs`

### Step 1: Generate Phoenix app

```bash
cd server && mix phx.new dust --binary-id --app dust && cd ..
```

Note: the directory is `server/` but the app name is `dust`. If `mix phx.new` creates a `dust/` subdirectory, move the contents into `server/`.

### Step 2: Update mix.exs deps

`server/mix.exs` — update `deps/0`:

```elixir
defp deps do
  [
    # Core Phoenix
    {:phoenix, "~> 1.7"},
    {:phoenix_ecto, "~> 4.5"},
    {:ecto_sql, "~> 3.10"},
    {:postgrex, ">= 0.0.0"},
    {:phoenix_live_view, "~> 1.0"},
    {:phoenix_live_dashboard, "~> 0.8"},
    {:bandit, "~> 1.5"},

    # Vite + Inertia
    {:phoenix_vite, "~> 0.4", runtime: Mix.env() == :dev},
    {:inertia, "~> 2.0"},

    # Auth
    {:workos, "~> 1.1"},
    {:req, "~> 0.5"},

    # Authorization
    {:let_me, "~> 1.2"},

    # Background jobs
    {:oban, "~> 2.18"},

    # Encryption (for token storage)
    {:cloak_ecto, "~> 1.3"},
    {:cloak, "~> 1.1"},

    # Protocol (shared with SDK)
    {:dust_protocol, path: "../protocol/elixir"},

    # Dev/Test
    {:tidewave, "~> 0.5", only: :dev},
    {:dotenv, "~> 3.0", only: [:dev, :test]},
    {:phoenix_html, "~> 4.1"},
    {:phoenix_live_reload, "~> 1.2", only: :dev},
    {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.0"},
    {:gettext, "~> 0.26"},
    {:jason, "~> 1.2"},
    {:dns_cluster, "~> 0.1.1"}
  ]
end
```

### Step 3: Configure UUIDv7 and generators

`server/config/config.exs` — add/update:

```elixir
config :dust,
  ecto_repos: [Dust.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  migration_primary_key: [name: :id, type: :binary_id, default: {:fragment, "uuidv7()"}],
  migration_foreign_key: [type: :binary_id]
```

### Step 4: Create base schema module

`server/lib/dust/schema.ex`:

```elixir
defmodule Dust.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
```

### Step 5: Create UUIDv7 bootstrap migration

```bash
cd server && mix ecto.gen.migration enable_uuidv7 && cd ..
```

Edit the generated migration:

```elixir
defmodule Dust.Repo.Migrations.EnableUuidv7 do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_uuidv7"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pg_uuidv7"
  end
end
```

### Step 6: Configure port (use 7000 for Dust)

`server/config/dev.exs`:

```elixir
config :dust, DustWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "7000")],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  secret_key_base: "dev-secret-at-least-64-bytes-long-for-dust-application-development-only",
  watchers: []
```

### Step 7: Add Tidewave to endpoint

`server/lib/dust_web/endpoint.ex` — add near the top:

```elixir
if Code.ensure_loaded?(Tidewave) do
  plug Tidewave
end
```

### Step 8: Create database, run migration, verify

```bash
cd server && mix deps.get && mix ecto.create && mix ecto.migrate && cd ..
```

### Step 9: Verify server starts

```bash
cd server && mix phx.server
```

Verify: visit `http://localhost:7000`. Should see Phoenix welcome page.

### Step 10: Commit

```bash
git add server/
git commit -m "feat: scaffold Phoenix server with UUIDv7, Tidewave, and dust_protocol dependency"
```

---

## Task 3: Dual Endpoints + Vite/Inertia

Set up the AdminWeb LiveView endpoint and the main DustWeb Inertia/React endpoint.

Follow Sections 5 and 6 of the Phoenix Architecture Guide. Key customizations for Dust:

**Files:**
- Create: `server/lib/admin_web.ex`
- Create: `server/lib/admin_web/endpoint.ex`
- Create: `server/lib/admin_web/router.ex`
- Create: `server/lib/admin_web/components/layouts/root.html.heex`
- Create: `server/lib/admin_web/components/layouts/app.html.heex`
- Create: `server/lib/admin_web/components/layouts.ex`
- Modify: `server/lib/dust_web.ex`
- Modify: `server/lib/dust_web/endpoint.ex`
- Modify: `server/lib/dust_web/router.ex`
- Create: `server/assets/vite.config.mjs`
- Create: `server/assets/package.json`
- Create: `server/assets/js/app.js`
- Create: `server/assets/js/admin.js`
- Modify: `server/config/config.exs`
- Modify: `server/config/dev.exs`
- Modify: `server/lib/dust/application.ex`

### Step 1: Create AdminWeb module

`server/lib/admin_web.ex`:

```elixir
defmodule AdminWeb do
  def static_paths, do: ~w(assets fonts images .vite favicon.ico robots.txt)

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {AdminWeb.Layouts, :app}
      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0]
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.Component
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AdminWeb.Endpoint,
        router: AdminWeb.Router,
        statics: AdminWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
```

### Step 2: Create AdminWeb endpoint

`server/lib/admin_web/endpoint.ex`:

```elixir
defmodule AdminWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :dust

  @session_options [
    store: :cookie,
    key: "_dust_key",
    signing_salt: "dust_admin_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  plug Plug.Static,
    at: "/",
    from: :dust,
    gzip: false,
    only: AdminWeb.static_paths()

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AdminWeb.Router
end
```

### Step 3: Create AdminWeb router

`server/lib/admin_web/router.ex`:

```elixir
defmodule AdminWeb.Router do
  use AdminWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AdminWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", AdminWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
  end
end
```

### Step 4: Create AdminWeb layouts

`server/lib/admin_web/components/layouts.ex`:

```elixir
defmodule AdminWeb.Layouts do
  use AdminWeb, :html

  embed_templates "layouts/*"
end
```

`server/lib/admin_web/components/layouts/root.html.heex`:

```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="csrf-token" content={get_csrf_token()} />
    <.live_title>{assigns[:page_title] || "Dust Admin"}</.live_title>
  </head>
  <body>
    {@inner_content}
  </body>
</html>
```

`server/lib/admin_web/components/layouts/app.html.heex`:

```heex
<main class="px-4 py-8">
  {@inner_content}
</main>
```

### Step 5: Create placeholder AdminWeb DashboardLive

`server/lib/admin_web/live/dashboard_live.ex`:

```elixir
defmodule AdminWeb.DashboardLive do
  use AdminWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Dashboard")}
  end

  def render(assigns) do
    ~H"""
    <h1>Dust Admin</h1>
    <p>Server is running.</p>
    """
  end
end
```

### Step 6: Configure both endpoints

`server/config/config.exs` — add AdminWeb endpoint config:

```elixir
config :dust, AdminWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Dust.PubSub,
  live_view: [signing_salt: "dust_admin_lv_salt"]
```

`server/config/dev.exs` — add AdminWeb dev config:

```elixir
config :dust, AdminWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("ADMIN_PORT") || "7001")],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  secret_key_base: "dev-secret-at-least-64-bytes-long-for-dust-admin-development-only"
```

### Step 7: Add AdminWeb.Endpoint to supervision tree

`server/lib/dust/application.ex` — add `AdminWeb.Endpoint` after `DustWeb.Endpoint` in the children list:

```elixir
children = [
  DustWeb.Telemetry,
  Dust.Repo,
  {Phoenix.PubSub, name: Dust.PubSub},
  DustWeb.Endpoint,
  AdminWeb.Endpoint
]
```

### Step 8: Verify both endpoints start

```bash
cd server && mix phx.server
```

Verify: `http://localhost:7000` (main) and `http://localhost:7001` (admin — should show "Dust Admin" page).

### Step 9: Commit

```bash
git add server/
git commit -m "feat: add AdminWeb LiveView endpoint on port 7001"
```

**Note:** Vite/Inertia setup for the main DustWeb endpoint (React dashboard) is deferred until after the sync engine works. The dashboard is not needed for the vertical slice smoke tests. When ready, follow Section 6 of the Phoenix Architecture Guide.

---

## Task 4: Accounts — Users, Orgs, Memberships

Create the accounts domain following Sections 7 and 8 of the Phoenix Architecture Guide.

**Files:**
- Create: `server/lib/dust/accounts/user.ex`
- Create: `server/lib/dust/accounts/organization.ex`
- Create: `server/lib/dust/accounts/organization_membership.ex`
- Create: `server/lib/dust/accounts/scope.ex`
- Create: `server/lib/dust/accounts.ex`
- Create: `server/priv/repo/migrations/*_create_users.exs`
- Create: `server/priv/repo/migrations/*_create_organizations.exs`
- Create: `server/priv/repo/migrations/*_create_organization_memberships.exs`
- Test: `server/test/dust/accounts_test.exs`

### Step 1: Create users migration

```bash
cd server && mix ecto.gen.migration create_users && cd ..
```

```elixir
defmodule Dust.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :workos_id, :string
      add :first_name, :string
      add :last_name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:workos_id])

    execute(
      "ALTER TABLE users ALTER COLUMN id SET DEFAULT uuidv7()",
      "ALTER TABLE users ALTER COLUMN id DROP DEFAULT"
    )
  end
end
```

### Step 2: Create organizations migration

```bash
cd server && mix ecto.gen.migration create_organizations && cd ..
```

```elixir
defmodule Dust.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :workos_organization_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organizations, [:slug])
    create unique_index(:organizations, [:workos_organization_id])
  end
end
```

### Step 3: Create organization_memberships migration

```bash
cd server && mix ecto.gen.migration create_organization_memberships && cd ..
```

```elixir
defmodule Dust.Repo.Migrations.CreateOrganizationMemberships do
  use Ecto.Migration

  def change do
    create table(:organization_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "member"
      add :deleted_at, :utc_datetime_usec
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:organization_memberships, [:user_id])
    create index(:organization_memberships, [:organization_id])
    create unique_index(:organization_memberships, [:user_id, :organization_id],
      where: "deleted_at IS NULL", name: :org_memberships_user_org_active)
  end
end
```

### Step 4: Create schema modules

`server/lib/dust/accounts/user.ex`:

```elixir
defmodule Dust.Accounts.User do
  use Dust.Schema

  schema "users" do
    field :email, :string
    field :workos_id, :string
    field :first_name, :string
    field :last_name, :string

    has_many :organization_memberships, Dust.Accounts.OrganizationMembership
    has_many :organizations, through: [:organization_memberships, :organization]

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> Ecto.Changeset.cast(attrs, [:email, :workos_id, :first_name, :last_name])
    |> Ecto.Changeset.validate_required([:email])
    |> Ecto.Changeset.unique_constraint(:email)
    |> Ecto.Changeset.unique_constraint(:workos_id)
  end
end
```

`server/lib/dust/accounts/organization.ex`:

```elixir
defmodule Dust.Accounts.Organization do
  use Dust.Schema

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :workos_organization_id, :string

    has_many :organization_memberships, Dust.Accounts.OrganizationMembership
    has_many :users, through: [:organization_memberships, :user]

    timestamps()
  end

  def changeset(org, attrs) do
    org
    |> Ecto.Changeset.cast(attrs, [:name, :slug, :workos_organization_id])
    |> Ecto.Changeset.validate_required([:name, :slug])
    |> Ecto.Changeset.unique_constraint(:slug)
    |> Ecto.Changeset.unique_constraint(:workos_organization_id)
    |> Ecto.Changeset.validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
  end
end
```

`server/lib/dust/accounts/organization_membership.ex`:

```elixir
defmodule Dust.Accounts.OrganizationMembership do
  use Dust.Schema

  schema "organization_memberships" do
    field :role, Ecto.Enum, values: [:owner, :admin, :member, :guest]
    field :deleted_at, :utc_datetime_usec

    belongs_to :user, Dust.Accounts.User
    belongs_to :organization, Dust.Accounts.Organization

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> Ecto.Changeset.cast(attrs, [:role, :user_id, :organization_id])
    |> Ecto.Changeset.validate_required([:role, :user_id, :organization_id])
    |> Ecto.Changeset.unique_constraint([:user_id, :organization_id],
      name: :org_memberships_user_org_active)
  end
end
```

`server/lib/dust/accounts/scope.ex`:

```elixir
defmodule Dust.Accounts.Scope do
  alias Dust.Accounts.{User, Organization}

  defstruct user: nil, organization: nil, api_key: nil

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  def put_organization(%__MODULE__{} = scope, %Organization{} = org) do
    %{scope | organization: org}
  end
end
```

### Step 5: Create accounts context

`server/lib/dust/accounts.ex`:

```elixir
defmodule Dust.Accounts do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Accounts.{User, Organization, OrganizationMembership}

  # Users

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) do
    Repo.get_by(User, email: email)
  end

  def get_user_by_workos_id(workos_id) do
    Repo.get_by(User, workos_id: workos_id)
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  # Organizations

  def get_organization_by_slug!(slug) do
    Repo.get_by!(Organization, slug: slug)
  end

  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  def create_organization_with_owner(%User{} = user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:organization, Organization.changeset(%Organization{}, attrs))
    |> Ecto.Multi.insert(:membership, fn %{organization: org} ->
      OrganizationMembership.changeset(%OrganizationMembership{}, %{
        user_id: user.id,
        organization_id: org.id,
        role: :owner
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: org}} -> {:ok, org}
      {:error, _, changeset, _} -> {:error, changeset}
    end
  end

  # Memberships

  def get_organization_membership(user, org) do
    Repo.get_by(OrganizationMembership, user_id: user.id, organization_id: org.id)
  end

  def ensure_membership(%User{} = user, %Organization{} = org, role \\ :member) do
    case get_organization_membership(user, org) do
      nil ->
        %OrganizationMembership{}
        |> OrganizationMembership.changeset(%{user_id: user.id, organization_id: org.id, role: role})
        |> Repo.insert()

      membership ->
        {:ok, membership}
    end
  end

  def list_user_organizations(%User{} = user) do
    from(o in Organization,
      join: m in OrganizationMembership,
      on: m.organization_id == o.id,
      where: m.user_id == ^user.id and is_nil(m.deleted_at),
      select: o
    )
    |> Repo.all()
  end
end
```

### Step 6: Write accounts tests

`server/test/dust/accounts_test.exs`:

```elixir
defmodule Dust.AccountsTest do
  use Dust.DataCase, async: true

  alias Dust.Accounts

  describe "users" do
    test "create_user/1 with valid attrs" do
      assert {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
      assert user.email == "test@example.com"
      assert user.id != nil
    end

    test "create_user/1 rejects duplicate email" do
      Accounts.create_user(%{email: "dupe@example.com"})
      assert {:error, changeset} = Accounts.create_user(%{email: "dupe@example.com"})
      assert errors_on(changeset).email != nil
    end
  end

  describe "organizations" do
    test "create_organization_with_owner/2 creates org and membership" do
      {:ok, user} = Accounts.create_user(%{email: "owner@example.com"})
      assert {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "James", slug: "james"})
      assert org.slug == "james"

      membership = Accounts.get_organization_membership(user, org)
      assert membership.role == :owner
    end

    test "slug must be lowercase alphanumeric" do
      {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
      assert {:error, _} = Accounts.create_organization_with_owner(user, %{name: "Bad", slug: "Bad Slug!"})
    end
  end
end
```

### Step 7: Run migrations and tests

```bash
cd server && mix ecto.migrate && mix test test/dust/accounts_test.exs && cd ..
```

### Step 8: Commit

```bash
git add server/
git commit -m "feat: add accounts domain — users, organizations, memberships, scope"
```

---

## Task 5: Stores, Tokens, and Devices

**Files:**
- Create: `server/lib/dust/stores/store.ex`
- Create: `server/lib/dust/stores/store_token.ex`
- Create: `server/lib/dust/stores/device.ex`
- Create: `server/lib/dust/stores.ex`
- Create: `server/priv/repo/migrations/*_create_stores.exs`
- Create: `server/priv/repo/migrations/*_create_store_tokens.exs`
- Create: `server/priv/repo/migrations/*_create_devices.exs`
- Test: `server/test/dust/stores_test.exs`

### Step 1: Create stores migration

```elixir
defmodule Dust.Repo.Migrations.CreateStores do
  use Ecto.Migration

  def change do
    create table(:stores, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stores, [:organization_id])
    create unique_index(:stores, [:organization_id, :name])
  end
end
```

### Step 2: Create store_tokens migration

```elixir
defmodule Dust.Repo.Migrations.CreateStoreTokens do
  use Ecto.Migration

  def change do
    create table(:store_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :permissions, :integer, null: false, default: 1
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:store_tokens, [:store_id])
    create unique_index(:store_tokens, [:token_hash])
  end
end
```

### Step 3: Create devices migration

```elixir
defmodule Dust.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_id, :string, null: false
      add :name, :string
      add :last_seen_at, :utc_datetime_usec
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:devices, [:device_id])
    create index(:devices, [:user_id])
  end
end
```

### Step 4: Create schema modules

`server/lib/dust/stores/store.ex`:

```elixir
defmodule Dust.Stores.Store do
  use Dust.Schema

  schema "stores" do
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active

    belongs_to :organization, Dust.Accounts.Organization

    has_many :store_tokens, Dust.Stores.StoreToken

    timestamps()
  end

  def changeset(store, attrs) do
    store
    |> Ecto.Changeset.cast(attrs, [:name, :status, :organization_id])
    |> Ecto.Changeset.validate_required([:name, :organization_id])
    |> Ecto.Changeset.unique_constraint([:organization_id, :name])
    |> Ecto.Changeset.validate_format(:name, ~r/^[a-z0-9][a-z0-9._-]*$/)
  end
end
```

`server/lib/dust/stores/store_token.ex`:

```elixir
defmodule Dust.Stores.StoreToken do
  use Dust.Schema

  @read_permission 1
  @write_permission 2

  schema "store_tokens" do
    field :name, :string
    field :token_hash, :binary
    field :permissions, :integer, default: 1
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :raw_token, :string, virtual: true

    belongs_to :store, Dust.Stores.Store
    belongs_to :created_by, Dust.Accounts.User, foreign_key: :created_by_id

    timestamps()
  end

  def can_read?(%__MODULE__{permissions: p}), do: Bitwise.band(p, @read_permission) != 0
  def can_write?(%__MODULE__{permissions: p}), do: Bitwise.band(p, @write_permission) != 0

  def permissions_integer(read?, write?) do
    (if read?, do: @read_permission, else: 0) + (if write?, do: @write_permission, else: 0)
  end

  def changeset(token, attrs) do
    token
    |> Ecto.Changeset.cast(attrs, [:name, :token_hash, :permissions, :expires_at, :store_id, :created_by_id])
    |> Ecto.Changeset.validate_required([:name, :token_hash, :permissions, :store_id])
    |> Ecto.Changeset.unique_constraint(:token_hash)
  end
end
```

`server/lib/dust/stores/device.ex`:

```elixir
defmodule Dust.Stores.Device do
  use Dust.Schema

  schema "devices" do
    field :device_id, :string
    field :name, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, Dust.Accounts.User

    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> Ecto.Changeset.cast(attrs, [:device_id, :name, :user_id])
    |> Ecto.Changeset.validate_required([:device_id])
    |> Ecto.Changeset.unique_constraint(:device_id)
  end
end
```

### Step 5: Create stores context

`server/lib/dust/stores.ex`:

```elixir
defmodule Dust.Stores do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Stores.{Store, StoreToken, Device}

  @token_prefix "dust_tok_"

  # Stores

  def create_store(organization, attrs) do
    %Store{}
    |> Store.changeset(Map.put(attrs, :organization_id, organization.id))
    |> Repo.insert()
  end

  def get_store!(id), do: Repo.get!(Store, id)

  def get_store_by_full_name(full_name) do
    case String.split(full_name, "/", parts: 2) do
      [org_slug, store_name] ->
        from(s in Store,
          join: o in assoc(s, :organization),
          where: o.slug == ^org_slug and s.name == ^store_name and s.status == :active,
          preload: [:organization]
        )
        |> Repo.one()

      _ ->
        nil
    end
  end

  # Tokens

  def create_store_token(store, attrs) do
    raw_token = generate_token()
    token_hash = hash_token(raw_token)

    permissions = StoreToken.permissions_integer(
      Map.get(attrs, :read, true),
      Map.get(attrs, :write, false)
    )

    result =
      %StoreToken{}
      |> StoreToken.changeset(%{
        name: attrs.name,
        token_hash: token_hash,
        permissions: permissions,
        expires_at: attrs[:expires_at],
        store_id: store.id,
        created_by_id: attrs[:created_by_id]
      })
      |> Repo.insert()

    case result do
      {:ok, token} -> {:ok, %{token | raw_token: raw_token}}
      error -> error
    end
  end

  def authenticate_token(@token_prefix <> _ = raw_token) do
    token_hash = hash_token(raw_token)

    from(t in StoreToken,
      where: t.token_hash == ^token_hash,
      where: is_nil(t.expires_at) or t.expires_at > ^DateTime.utc_now(),
      preload: [store: :organization]
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid_token}
      token ->
        Repo.update(Ecto.Changeset.change(token, last_used_at: DateTime.utc_now()))
        {:ok, token}
    end
  end

  def authenticate_token(_), do: {:error, :invalid_token}

  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token)
  end

  # Devices

  def ensure_device(device_id, user_id \\ nil) do
    case Repo.get_by(Device, device_id: device_id) do
      nil ->
        %Device{}
        |> Device.changeset(%{device_id: device_id, user_id: user_id, last_seen_at: DateTime.utc_now()})
        |> Repo.insert()

      device ->
        device
        |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
        |> Repo.update()
    end
  end
end
```

### Step 6: Write stores tests

`server/test/dust/stores_test.exs`:

```elixir
defmodule Dust.StoresTest do
  use Dust.DataCase, async: true

  alias Dust.{Accounts, Stores}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "James", slug: "james"})
    %{user: user, org: org}
  end

  describe "stores" do
    test "create and retrieve by full name", %{org: org} do
      {:ok, store} = Stores.create_store(org, %{name: "blog"})
      assert store.name == "blog"

      found = Stores.get_store_by_full_name("james/blog")
      assert found.id == store.id
    end

    test "full name lookup returns nil for nonexistent store" do
      assert Stores.get_store_by_full_name("james/nope") == nil
    end
  end

  describe "tokens" do
    test "create and authenticate", %{org: org, user: user} do
      {:ok, store} = Stores.create_store(org, %{name: "blog"})
      {:ok, token} = Stores.create_store_token(store, %{name: "test", read: true, write: true, created_by_id: user.id})

      assert String.starts_with?(token.raw_token, "dust_tok_")

      {:ok, authed} = Stores.authenticate_token(token.raw_token)
      assert authed.store_id == store.id
      assert Stores.StoreToken.can_read?(authed)
      assert Stores.StoreToken.can_write?(authed)
    end

    test "rejects invalid token" do
      assert {:error, :invalid_token} = Stores.authenticate_token("dust_tok_bogus")
    end

    test "rejects non-prefixed token" do
      assert {:error, :invalid_token} = Stores.authenticate_token("not_a_token")
    end
  end

  describe "devices" do
    test "ensure_device creates on first call" do
      {:ok, device} = Stores.ensure_device("dev_abc")
      assert device.device_id == "dev_abc"
    end

    test "ensure_device updates last_seen on second call" do
      {:ok, first} = Stores.ensure_device("dev_abc")
      {:ok, second} = Stores.ensure_device("dev_abc")
      assert second.id == first.id
    end
  end
end
```

### Step 7: Run migrations and tests

```bash
cd server && mix ecto.migrate && mix test test/dust/stores_test.exs && cd ..
```

### Step 8: Commit

```bash
git add server/
git commit -m "feat: add stores domain — stores, scoped tokens, devices"
```

---

## Task 6: Sync Engine Tables

**Files:**
- Create: `server/priv/repo/migrations/*_create_store_ops.exs`
- Create: `server/priv/repo/migrations/*_create_store_entries.exs`
- Create: `server/priv/repo/migrations/*_create_store_snapshots.exs`
- Create: `server/lib/dust/sync/store_op.ex`
- Create: `server/lib/dust/sync/store_entry.ex`
- Create: `server/lib/dust/sync/store_snapshot.ex`

### Step 1: Create store_ops migration

```elixir
defmodule Dust.Repo.Migrations.CreateStoreOps do
  use Ecto.Migration

  def change do
    create table(:store_ops, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :store_seq, :bigint, null: false
      add :op, :string, null: false
      add :path, :string, null: false
      add :value, :map
      add :type, :string, null: false, default: "map"
      add :device_id, :string, null: false
      add :client_op_id, :string, null: false
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:store_ops, [:store_id, :store_seq], unique: true)
    create index(:store_ops, [:store_id, :path])
  end
end
```

### Step 2: Create store_entries migration

```elixir
defmodule Dust.Repo.Migrations.CreateStoreEntries do
  use Ecto.Migration

  def change do
    create table(:store_entries, primary_key: false) do
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :value, :map
      add :type, :string, null: false, default: "map"
      add :seq, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE store_entries ADD PRIMARY KEY (store_id, path)",
      "ALTER TABLE store_entries DROP CONSTRAINT store_entries_pkey"
    )
  end
end
```

### Step 3: Create store_snapshots migration

```elixir
defmodule Dust.Repo.Migrations.CreateStoreSnapshots do
  use Ecto.Migration

  def change do
    create table(:store_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :snapshot_seq, :bigint, null: false
      add :snapshot_data, :map, null: false
      add :store_id, references(:stores, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:store_snapshots, [:store_id, :snapshot_seq])
  end
end
```

### Step 4: Create schema modules

`server/lib/dust/sync/store_op.ex`:

```elixir
defmodule Dust.Sync.StoreOp do
  use Dust.Schema

  schema "store_ops" do
    field :store_seq, :integer
    field :op, Ecto.Enum, values: [:set, :delete, :merge]
    field :path, :string
    field :value, :map
    field :type, :string, default: "map"
    field :device_id, :string
    field :client_op_id, :string

    belongs_to :store, Dust.Stores.Store

    timestamps(updated_at: false)
  end
end
```

`server/lib/dust/sync/store_entry.ex`:

```elixir
defmodule Dust.Sync.StoreEntry do
  use Ecto.Schema

  @primary_key false
  schema "store_entries" do
    field :store_id, :binary_id, primary_key: true
    field :path, :string, primary_key: true
    field :value, :map
    field :type, :string, default: "map"
    field :seq, :integer

    timestamps()
  end
end
```

`server/lib/dust/sync/store_snapshot.ex`:

```elixir
defmodule Dust.Sync.StoreSnapshot do
  use Dust.Schema

  schema "store_snapshots" do
    field :snapshot_seq, :integer
    field :snapshot_data, :map

    belongs_to :store, Dust.Stores.Store

    timestamps(updated_at: false)
  end
end
```

### Step 5: Run migrations

```bash
cd server && mix ecto.migrate && cd ..
```

### Step 6: Commit

```bash
git add server/
git commit -m "feat: add sync engine tables — store_ops, store_entries, store_snapshots"
```

---

## Task 7: Store Writer GenServer

The core of the sync engine — serializes writes per store, applies conflict resolution, persists to both tables, broadcasts via PubSub.

**Files:**
- Create: `server/lib/dust/sync/writer.ex`
- Create: `server/lib/dust/sync/conflict.ex`
- Create: `server/lib/dust/sync.ex`
- Test: `server/test/dust/sync/writer_test.exs`
- Test: `server/test/dust/sync/conflict_test.exs`

### Step 1: Write failing conflict resolution tests

`server/test/dust/sync/conflict_test.exs`:

```elixir
defmodule Dust.Sync.ConflictTest do
  use ExUnit.Case, async: true

  alias Dust.Sync.Conflict

  describe "apply_set/2" do
    test "replaces value at exact path" do
      entries = %{"posts.hello" => %{value: %{"title" => "Old"}, type: "map"}}
      result = Conflict.apply_set(entries, "posts.hello", %{"title" => "New"}, "map")
      assert result["posts.hello"].value == %{"title" => "New"}
    end

    test "deletes descendant entries when setting ancestor" do
      entries = %{
        "posts.hello.title" => %{value: "Hello", type: "string"},
        "posts.hello.body" => %{value: "Body", type: "string"},
        "posts.other" => %{value: "Other", type: "string"}
      }
      result = Conflict.apply_set(entries, "posts.hello", %{"title" => "Replaced"}, "map")
      assert Map.has_key?(result, "posts.hello")
      refute Map.has_key?(result, "posts.hello.title")
      refute Map.has_key?(result, "posts.hello.body")
      assert Map.has_key?(result, "posts.other")
    end
  end

  describe "apply_delete/2" do
    test "removes path and descendants" do
      entries = %{
        "posts.hello" => %{value: %{}, type: "map"},
        "posts.hello.title" => %{value: "Hello", type: "string"},
        "posts.other" => %{value: "Other", type: "string"}
      }
      result = Conflict.apply_delete(entries, "posts.hello")
      refute Map.has_key?(result, "posts.hello")
      refute Map.has_key?(result, "posts.hello.title")
      assert Map.has_key?(result, "posts.other")
    end
  end

  describe "apply_merge/2" do
    test "updates named children, leaves siblings alone" do
      entries = %{
        "settings.theme" => %{value: "light", type: "string"},
        "settings.locale" => %{value: "en", type: "string"}
      }
      result = Conflict.apply_merge(entries, "settings", %{"theme" => "dark"}, "string")
      assert result["settings.theme"].value == "dark"
      assert result["settings.locale"].value == "en"
    end

    test "creates new children that don't exist" do
      entries = %{
        "settings.theme" => %{value: "light", type: "string"}
      }
      result = Conflict.apply_merge(entries, "settings", %{"locale" => "en"}, "string")
      assert result["settings.theme"].value == "light"
      assert result["settings.locale"].value == "en"
    end
  end
end
```

### Step 2: Run tests, verify they fail

```bash
cd server && mix test test/dust/sync/conflict_test.exs
```

### Step 3: Implement conflict resolution

`server/lib/dust/sync/conflict.ex`:

```elixir
defmodule Dust.Sync.Conflict do
  alias DustProtocol.Path

  @doc "Apply a set operation to the entry map. Replaces value at path and removes descendants."
  def apply_set(entries, path, value, type) do
    {:ok, segments} = Path.parse(path)

    entries
    |> remove_descendants(segments)
    |> Map.put(path, %{value: value, type: type})
  end

  @doc "Apply a delete operation. Removes the path and all descendants."
  def apply_delete(entries, path) do
    {:ok, segments} = Path.parse(path)

    entries
    |> Map.delete(path)
    |> remove_descendants(segments)
  end

  @doc "Apply a merge operation. Updates named children, leaves siblings alone."
  def apply_merge(entries, path, map, child_type) when is_map(map) do
    Enum.reduce(map, entries, fn {key, value}, acc ->
      child_path = "#{path}.#{key}"
      Map.put(acc, child_path, %{value: value, type: child_type})
    end)
  end

  defp remove_descendants(entries, ancestor_segments) do
    Map.reject(entries, fn {entry_path, _} ->
      case Path.parse(entry_path) do
        {:ok, entry_segments} -> Path.ancestor?(ancestor_segments, entry_segments)
        _ -> false
      end
    end)
  end
end
```

### Step 4: Run conflict tests, verify they pass

```bash
cd server && mix test test/dust/sync/conflict_test.exs
```

### Step 5: Write failing writer tests

`server/test/dust/sync/writer_test.exs`:

```elixir
defmodule Dust.Sync.WriterTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "writer@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "test"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store}
  end

  describe "write/1" do
    test "set assigns store_seq and persists", %{store: store} do
      {:ok, event} = Sync.write(store.id, %{
        op: :set,
        path: "posts.hello",
        value: %{"title" => "Hello"},
        device_id: "dev_1",
        client_op_id: "op_1"
      })

      assert event.store_seq == 1
      assert event.op == :set
      assert event.path == "posts.hello"

      # Verify materialized entry
      entry = Sync.get_entry(store.id, "posts.hello")
      assert entry.value == %{"title" => "Hello"}
      assert entry.seq == 1
    end

    test "sequential writes increment store_seq", %{store: store} do
      {:ok, e1} = Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      {:ok, e2} = Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})
      assert e1.store_seq == 1
      assert e2.store_seq == 2
    end

    test "delete removes entry", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "x", value: "v", device_id: "d", client_op_id: "o1"})
      {:ok, _} = Sync.write(store.id, %{op: :delete, path: "x", value: nil, device_id: "d", client_op_id: "o2"})

      assert Sync.get_entry(store.id, "x") == nil
    end

    test "merge updates named children only", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "settings.theme", value: "light", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "settings.locale", value: "en", device_id: "d", client_op_id: "o2"})
      Sync.write(store.id, %{op: :merge, path: "settings", value: %{"theme" => "dark"}, device_id: "d", client_op_id: "o3"})

      assert Sync.get_entry(store.id, "settings.theme").value == "dark"
      assert Sync.get_entry(store.id, "settings.locale").value == "en"
    end
  end

  describe "get_ops_since/2" do
    test "returns ops after given seq", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})
      Sync.write(store.id, %{op: :set, path: "c", value: "3", device_id: "d", client_op_id: "o3"})

      ops = Sync.get_ops_since(store.id, 1)
      assert length(ops) == 2
      assert Enum.map(ops, & &1.store_seq) == [2, 3]
    end
  end
end
```

### Step 6: Implement writer GenServer and sync context

`server/lib/dust/sync/writer.ex`:

```elixir
defmodule Dust.Sync.Writer do
  use GenServer

  alias Dust.Repo
  alias Dust.Sync.{StoreOp, StoreEntry, Conflict}

  import Ecto.Query

  @idle_timeout :timer.minutes(15)

  def start_link(store_id) do
    GenServer.start_link(__MODULE__, store_id, name: via(store_id))
  end

  def write(store_id, op_attrs) do
    pid = ensure_started(store_id)
    GenServer.call(pid, {:write, op_attrs})
  end

  def via(store_id) do
    {:via, Registry, {Dust.Sync.WriterRegistry, store_id}}
  end

  defp ensure_started(store_id) do
    case Registry.lookup(Dust.Sync.WriterRegistry, store_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               Dust.Sync.WriterSupervisor,
               {__MODULE__, store_id}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  # Server callbacks

  @impl true
  def init(store_id) do
    {:ok, %{store_id: store_id}, @idle_timeout}
  end

  @impl true
  def handle_call({:write, op_attrs}, _from, state) do
    result = do_write(state.store_id, op_attrs)
    {:reply, result, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  defp do_write(store_id, attrs) do
    Repo.transaction(fn ->
      # Get current max store_seq (lock the row via FOR UPDATE on a subquery)
      current_seq =
        from(o in StoreOp,
          where: o.store_id == ^store_id,
          select: max(o.store_seq)
        )
        |> Repo.one() || 0

      next_seq = current_seq + 1

      # Insert op
      op =
        %StoreOp{
          store_seq: next_seq,
          op: attrs.op,
          path: attrs.path,
          value: attrs[:value],
          type: attrs[:type] || detect_type(attrs[:value]),
          device_id: attrs.device_id,
          client_op_id: attrs.client_op_id,
          store_id: store_id
        }
        |> Repo.insert!()

      # Apply to materialized state
      apply_to_entries(store_id, next_seq, attrs)

      # Broadcast via PubSub
      Phoenix.PubSub.broadcast(
        Dust.PubSub,
        "store:#{store_id}",
        {:store_event, %{
          store_id: store_id,
          store_seq: next_seq,
          op: attrs.op,
          path: attrs.path,
          value: attrs[:value],
          device_id: attrs.device_id,
          client_op_id: attrs.client_op_id
        }}
      )

      op
    end)
  end

  defp apply_to_entries(store_id, seq, %{op: :set, path: path, value: value} = attrs) do
    type = attrs[:type] || detect_type(value)

    # Delete descendants
    {:ok, segments} = DustProtocol.Path.parse(path)
    delete_descendants(store_id, segments)

    # Upsert entry
    Repo.insert!(
      %StoreEntry{store_id: store_id, path: path, value: wrap_value(value), type: type, seq: seq},
      on_conflict: [set: [value: wrap_value(value), type: type, seq: seq]],
      conflict_target: [:store_id, :path]
    )
  end

  defp apply_to_entries(store_id, _seq, %{op: :delete, path: path}) do
    {:ok, segments} = DustProtocol.Path.parse(path)

    from(e in StoreEntry, where: e.store_id == ^store_id and e.path == ^path)
    |> Repo.delete_all()

    delete_descendants(store_id, segments)
  end

  defp apply_to_entries(store_id, seq, %{op: :merge, path: path, value: map}) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      child_path = "#{path}.#{key}"
      type = detect_type(value)

      Repo.insert!(
        %StoreEntry{store_id: store_id, path: child_path, value: wrap_value(value), type: type, seq: seq},
        on_conflict: [set: [value: wrap_value(value), type: type, seq: seq]],
        conflict_target: [:store_id, :path]
      )
    end)
  end

  defp delete_descendants(store_id, ancestor_segments) do
    prefix = Enum.join(ancestor_segments, ".") <> "."

    from(e in StoreEntry,
      where: e.store_id == ^store_id and like(e.path, ^"#{prefix}%")
    )
    |> Repo.delete_all()
  end

  defp detect_type(value) when is_map(value), do: "map"
  defp detect_type(value) when is_binary(value), do: "string"
  defp detect_type(value) when is_integer(value), do: "integer"
  defp detect_type(value) when is_float(value), do: "float"
  defp detect_type(value) when is_boolean(value), do: "boolean"
  defp detect_type(nil), do: "null"
  defp detect_type(_), do: "string"

  # StoreEntry.value is :map type, so wrap scalars
  defp wrap_value(value) when is_map(value), do: value
  defp wrap_value(value), do: %{"_scalar" => value}
end
```

`server/lib/dust/sync.ex`:

```elixir
defmodule Dust.Sync do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Sync.{Writer, StoreOp, StoreEntry}

  def write(store_id, op_attrs) do
    Writer.write(store_id, op_attrs)
  end

  def get_entry(store_id, path) do
    Repo.get_by(StoreEntry, store_id: store_id, path: path)
  end

  def get_all_entries(store_id) do
    from(e in StoreEntry, where: e.store_id == ^store_id, order_by: e.path)
    |> Repo.all()
  end

  def get_ops_since(store_id, since_seq) do
    from(o in StoreOp,
      where: o.store_id == ^store_id and o.store_seq > ^since_seq,
      order_by: [asc: o.store_seq]
    )
    |> Repo.all()
  end

  def current_seq(store_id) do
    from(o in StoreOp,
      where: o.store_id == ^store_id,
      select: max(o.store_seq)
    )
    |> Repo.one() || 0
  end
end
```

### Step 7: Register writer infrastructure in application.ex

Add to the children list in `server/lib/dust/application.ex`:

```elixir
{Registry, keys: :unique, name: Dust.Sync.WriterRegistry},
{DynamicSupervisor, name: Dust.Sync.WriterSupervisor, strategy: :one_for_one},
```

Place these before the endpoint entries.

### Step 8: Run writer tests

```bash
cd server && mix test test/dust/sync/writer_test.exs
```

### Step 9: Commit

```bash
git add server/
git commit -m "feat: add store writer GenServer with conflict resolution and PubSub broadcast"
```

---

## Task 8: Phoenix Channel + WebSocket Sync

Wire up the WebSocket endpoint with Channel, custom serializers, and catch-up sync.

**Files:**
- Create: `server/lib/dust_web/channels/store_channel.ex`
- Create: `server/lib/dust_web/channels/store_socket.ex`
- Modify: `server/lib/dust_web/endpoint.ex`
- Test: `server/test/dust_web/channels/store_channel_test.exs`

### Step 1: Create the socket module

`server/lib/dust_web/channels/store_socket.ex`:

```elixir
defmodule DustWeb.StoreSocket do
  use Phoenix.Socket

  channel "store:*", DustWeb.StoreChannel

  @impl true
  def connect(%{"token" => token, "device_id" => device_id, "capver" => capver}, socket, _connect_info) do
    case Dust.Stores.authenticate_token(token) do
      {:ok, store_token} ->
        Dust.Stores.ensure_device(device_id)

        socket =
          socket
          |> assign(:store_token, store_token)
          |> assign(:device_id, device_id)
          |> assign(:capver, capver)

        {:ok, socket}

      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "store_socket:#{socket.assigns.device_id}"
end
```

### Step 2: Add socket to endpoint

`server/lib/dust_web/endpoint.ex` — add before the `plug Plug.Static` line:

```elixir
socket "/ws/sync", DustWeb.StoreSocket,
  websocket: [
    connect_info: [:peer_data],
    serializer: [{Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}]
  ]
```

### Step 3: Write failing channel tests

`server/test/dust_web/channels/store_channel_test.exs`:

```elixir
defmodule DustWeb.StoreChannelTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "channel@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "test"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    {:ok, token} = Stores.create_store_token(store, %{name: "rw", read: true, write: true, created_by_id: user.id})

    socket = socket(DustWeb.StoreSocket, "test", %{
      store_token: Stores.authenticate_token(token.raw_token) |> elem(1),
      device_id: "dev_test",
      capver: 1
    })

    %{socket: socket, store: store, token: token}
  end

  describe "join" do
    test "joins with valid store and receives catch-up", %{socket: socket, store: store} do
      # Write some data first
      Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})

      {:ok, reply, _socket} = subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{"last_store_seq" => 0})
      assert reply.store_seq == 2

      # Should receive catch-up events
      assert_push "event", %{store_seq: 1, path: "a"}
      assert_push "event", %{store_seq: 2, path: "b"}
    end
  end

  describe "write" do
    test "write broadcasts to all subscribers", %{socket: socket, store: store} do
      {:ok, _, socket} = subscribe_and_join(socket, DustWeb.StoreChannel, "store:#{store.id}", %{"last_store_seq" => 0})

      ref = push(socket, "write", %{
        "op" => "set",
        "path" => "posts.hello",
        "value" => %{"title" => "Hello"},
        "client_op_id" => "op_1"
      })

      assert_reply ref, :ok, %{store_seq: 1}
      assert_broadcast "event", %{store_seq: 1, op: :set, path: "posts.hello"}
    end
  end
end
```

### Step 4: Implement the channel

`server/lib/dust_web/channels/store_channel.ex`:

```elixir
defmodule DustWeb.StoreChannel do
  use Phoenix.Channel

  alias Dust.{Stores, Sync}

  @impl true
  def join("store:" <> store_id, %{"last_store_seq" => last_seq}, socket) do
    store_token = socket.assigns.store_token

    if store_token.store_id == store_id and Stores.StoreToken.can_read?(store_token) do
      send(self(), {:catch_up, last_seq})

      current_seq = Sync.current_seq(store_id)
      socket = assign(socket, :store_id, store_id)

      {:ok, %{store_seq: current_seq}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("write", params, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      op_attrs = %{
        op: String.to_existing_atom(params["op"]),
        path: params["path"],
        value: params["value"],
        device_id: socket.assigns.device_id,
        client_op_id: params["client_op_id"]
      }

      case Sync.write(socket.assigns.store_id, op_attrs) do
        {:ok, op} ->
          broadcast!(socket, "event", %{
            store_seq: op.store_seq,
            op: op.op,
            path: op.path,
            value: params["value"],
            device_id: socket.assigns.device_id,
            client_op_id: params["client_op_id"]
          })

          {:reply, {:ok, %{store_seq: op.store_seq}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: inspect(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_info({:catch_up, last_seq}, socket) do
    ops = Sync.get_ops_since(socket.assigns.store_id, last_seq)

    Enum.each(ops, fn op ->
      push(socket, "event", %{
        store_seq: op.store_seq,
        op: op.op,
        path: op.path,
        value: op.value,
        device_id: op.device_id,
        client_op_id: op.client_op_id
      })
    end)

    {:noreply, socket}
  end
end
```

### Step 5: Run channel tests

```bash
cd server && mix test test/dust_web/channels/store_channel_test.exs
```

### Step 6: Commit

```bash
git add server/
git commit -m "feat: add StoreChannel with WebSocket sync, auth, and catch-up"
```

---

## Task 9: SDK Scaffolding + Cache Adapter

Initialize the Elixir SDK library with the cache adapter behaviour and Ecto implementation.

**Files:**
- Create: `sdk/elixir/mix.exs`
- Create: `sdk/elixir/lib/dust.ex`
- Create: `sdk/elixir/lib/dust/cache.ex`
- Create: `sdk/elixir/lib/dust/cache/ecto.ex`
- Create: `sdk/elixir/lib/dust/cache/memory.ex`
- Test: `sdk/elixir/test/dust/cache/memory_test.exs`

### Step 1: Initialize SDK project

```bash
cd sdk/elixir && mix new dust && cd ../..
```

Move contents from `sdk/elixir/dust/` up to `sdk/elixir/` if `mix new` creates a subdirectory.

### Step 2: Update mix.exs

`sdk/elixir/mix.exs`:

```elixir
defmodule Dust.MixProject do
  use Mix.Project

  def project do
    [
      app: :dust,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:dust_protocol, path: "../../protocol/elixir"},
      {:mint_web_socket, "~> 1.0"},
      {:msgpax, "~> 2.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
```

### Step 3: Write cache behaviour

`sdk/elixir/lib/dust/cache.ex`:

```elixir
defmodule Dust.Cache do
  @callback read(store :: String.t(), path :: String.t()) :: {:ok, term()} | :miss
  @callback read_all(store :: String.t(), pattern :: String.t()) :: [{String.t(), term()}]
  @callback write(store :: String.t(), path :: String.t(), value :: term(), type :: String.t(), seq :: integer()) :: :ok
  @callback write_batch(store :: String.t(), entries :: [{String.t(), term(), String.t(), integer()}]) :: :ok
  @callback delete(store :: String.t(), path :: String.t()) :: :ok
  @callback last_seq(store :: String.t()) :: integer()
end
```

### Step 4: Write failing memory cache tests

`sdk/elixir/test/dust/cache/memory_test.exs`:

```elixir
defmodule Dust.Cache.MemoryTest do
  use ExUnit.Case, async: true

  alias Dust.Cache.Memory

  setup do
    {:ok, pid} = Memory.start_link([])
    %{cache: pid}
  end

  test "write and read", %{cache: cache} do
    :ok = Memory.write(cache, "store", "posts.hello", %{"title" => "Hello"}, "map", 1)
    assert {:ok, %{"title" => "Hello"}} = Memory.read(cache, "store", "posts.hello")
  end

  test "read returns :miss for unknown path", %{cache: cache} do
    assert :miss = Memory.read(cache, "store", "nope")
  end

  test "delete removes entry", %{cache: cache} do
    Memory.write(cache, "store", "x", "v", "string", 1)
    :ok = Memory.delete(cache, "store", "x")
    assert :miss = Memory.read(cache, "store", "x")
  end

  test "last_seq returns 0 initially", %{cache: cache} do
    assert Memory.last_seq(cache, "store") == 0
  end

  test "last_seq tracks highest seq", %{cache: cache} do
    Memory.write(cache, "store", "a", "1", "string", 5)
    Memory.write(cache, "store", "b", "2", "string", 3)
    assert Memory.last_seq(cache, "store") == 5
  end

  test "read_all with glob pattern", %{cache: cache} do
    Memory.write(cache, "store", "posts.a", "1", "string", 1)
    Memory.write(cache, "store", "posts.b", "2", "string", 2)
    Memory.write(cache, "store", "config.x", "3", "string", 3)

    results = Memory.read_all(cache, "store", "posts.*")
    assert length(results) == 2
    paths = Enum.map(results, &elem(&1, 0))
    assert "posts.a" in paths
    assert "posts.b" in paths
  end
end
```

### Step 5: Run tests, verify they fail

```bash
cd sdk/elixir && mix test test/dust/cache/memory_test.exs
```

### Step 6: Implement memory cache

`sdk/elixir/lib/dust/cache/memory.ex`:

```elixir
defmodule Dust.Cache.Memory do
  use GenServer
  @behaviour Dust.Cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @impl Dust.Cache
  def read(pid, store, path) do
    GenServer.call(pid, {:read, store, path})
  end

  @impl Dust.Cache
  def read_all(pid, store, pattern) do
    GenServer.call(pid, {:read_all, store, pattern})
  end

  @impl Dust.Cache
  def write(pid, store, path, value, type, seq) do
    GenServer.call(pid, {:write, store, path, value, type, seq})
  end

  @impl Dust.Cache
  def write_batch(pid, store, entries) do
    GenServer.call(pid, {:write_batch, store, entries})
  end

  @impl Dust.Cache
  def delete(pid, store, path) do
    GenServer.call(pid, {:delete, store, path})
  end

  @impl Dust.Cache
  def last_seq(pid, store) do
    GenServer.call(pid, {:last_seq, store})
  end

  # Server

  @impl true
  def init(_) do
    {:ok, %{entries: %{}, seqs: %{}}}
  end

  @impl true
  def handle_call({:read, store, path}, _from, state) do
    key = {store, path}
    case Map.get(state.entries, key) do
      nil -> {:reply, :miss, state}
      {value, _type, _seq} -> {:reply, {:ok, value}, state}
    end
  end

  @impl true
  def handle_call({:read_all, store, pattern}, _from, state) do
    compiled = DustProtocol.Glob.compile(pattern)

    results =
      state.entries
      |> Enum.filter(fn {{s, path}, _} ->
        s == store and DustProtocol.Glob.match?(compiled, String.split(path, "."))
      end)
      |> Enum.map(fn {{_s, path}, {value, _type, _seq}} -> {path, value} end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:write, store, path, value, type, seq}, _from, state) do
    state = put_in(state.entries[{store, path}], {value, type, seq})
    current = Map.get(state.seqs, store, 0)
    state = put_in(state.seqs[store], max(current, seq))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:write_batch, store, entries}, _from, state) do
    state =
      Enum.reduce(entries, state, fn {path, value, type, seq}, acc ->
        acc = put_in(acc.entries[{store, path}], {value, type, seq})
        current = Map.get(acc.seqs, store, 0)
        put_in(acc.seqs[store], max(current, seq))
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, store, path}, _from, state) do
    state = update_in(state.entries, &Map.delete(&1, {store, path}))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:last_seq, store}, _from, state) do
    {:reply, Map.get(state.seqs, store, 0), state}
  end
end
```

### Step 7: Run tests, verify they pass

```bash
cd sdk/elixir && mix test
```

### Step 8: Commit

```bash
git add sdk/
git commit -m "feat: add SDK scaffolding with cache behaviour and memory adapter"
```

---

## Task 10: SDK Sync Engine + Connection

The WebSocket client that connects to the server, handles catch-up, and dispatches events.

**Files:**
- Create: `sdk/elixir/lib/dust/connection.ex`
- Create: `sdk/elixir/lib/dust/sync_engine.ex`
- Create: `sdk/elixir/lib/dust/callback_registry.ex`
- Create: `sdk/elixir/lib/dust/supervisor.ex`
- Modify: `sdk/elixir/lib/dust.ex`
- Test: `sdk/elixir/test/dust/callback_registry_test.exs`
- Test: `sdk/elixir/test/dust/sync_engine_test.exs`

### Step 1: Write callback registry tests

`sdk/elixir/test/dust/callback_registry_test.exs`:

```elixir
defmodule Dust.CallbackRegistryTest do
  use ExUnit.Case, async: true

  alias Dust.CallbackRegistry

  setup do
    table = CallbackRegistry.new()
    %{table: table}
  end

  test "register and match", %{table: table} do
    test_pid = self()
    callback = fn event -> send(test_pid, {:callback, event}) end

    ref = CallbackRegistry.register(table, "james/blog", "posts.*", callback)
    assert is_reference(ref)

    callbacks = CallbackRegistry.match(table, "james/blog", "posts.hello")
    assert length(callbacks) == 1

    hd(callbacks).(%{path: "posts.hello"})
    assert_receive {:callback, %{path: "posts.hello"}}
  end

  test "does not match wrong store", %{table: table} do
    CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    assert CallbackRegistry.match(table, "other/store", "posts.hello") == []
  end

  test "does not match wrong pattern", %{table: table} do
    CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    assert CallbackRegistry.match(table, "james/blog", "config.x") == []
  end

  test "unregister removes callback", %{table: table} do
    ref = CallbackRegistry.register(table, "james/blog", "posts.*", fn _ -> :ok end)
    CallbackRegistry.unregister(table, ref)
    assert CallbackRegistry.match(table, "james/blog", "posts.hello") == []
  end
end
```

### Step 2: Implement callback registry

`sdk/elixir/lib/dust/callback_registry.ex`:

```elixir
defmodule Dust.CallbackRegistry do
  def new do
    :ets.new(:dust_callbacks, [:bag, :public])
  end

  def register(table, store, pattern, callback) when is_function(callback, 1) do
    ref = make_ref()
    compiled = DustProtocol.Glob.compile(pattern)
    :ets.insert(table, {store, compiled, pattern, callback, ref})
    ref
  end

  def unregister(table, ref) do
    :ets.match_delete(table, {:_, :_, :_, :_, ref})
    :ok
  end

  def match(table, store, path) do
    path_segments = String.split(path, ".")

    :ets.lookup(table, store)
    |> Enum.filter(fn {_store, compiled, _pattern, _callback, _ref} ->
      DustProtocol.Glob.match?(compiled, path_segments)
    end)
    |> Enum.map(fn {_store, _compiled, _pattern, callback, _ref} -> callback end)
  end
end
```

### Step 3: Run callback registry tests

```bash
cd sdk/elixir && mix test test/dust/callback_registry_test.exs
```

### Step 4: Implement sync engine

`sdk/elixir/lib/dust/sync_engine.ex`:

```elixir
defmodule Dust.SyncEngine do
  use GenServer

  defstruct [:store, :cache, :cache_pid, :callbacks, :pending_ops, :status, :last_store_seq]

  def start_link(opts) do
    store = Keyword.fetch!(opts, :store)
    GenServer.start_link(__MODULE__, opts, name: via(store))
  end

  def via(store), do: {:via, Registry, {Dust.SyncEngineRegistry, store}}

  def get(store, path) do
    GenServer.call(via(store), {:get, path})
  end

  def put(store, path, value) do
    GenServer.call(via(store), {:put, path, value})
  end

  def delete(store, path) do
    GenServer.call(via(store), {:delete, path})
  end

  def merge(store, path, map) do
    GenServer.call(via(store), {:merge, path, map})
  end

  def enum(store, pattern) do
    GenServer.call(via(store), {:enum, pattern})
  end

  def status(store) do
    GenServer.call(via(store), :status)
  end

  def on(store, pattern, callback) do
    GenServer.call(via(store), {:on, pattern, callback})
  end

  def handle_server_event(store, event) do
    GenServer.cast(via(store), {:server_event, event})
  end

  # Server

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    {cache_mod, cache_opts} = Keyword.fetch!(opts, :cache)

    cache_pid =
      case cache_opts do
        opts when is_list(opts) ->
          {:ok, pid} = cache_mod.start_link(opts)
          pid
        pid when is_pid(pid) ->
          pid
      end

    callbacks = Dust.CallbackRegistry.new()
    last_seq = cache_mod.last_seq(cache_pid, store)

    state = %__MODULE__{
      store: store,
      cache: cache_mod,
      cache_pid: cache_pid,
      callbacks: callbacks,
      pending_ops: %{},
      status: :disconnected,
      last_store_seq: last_seq
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get, path}, _from, state) do
    result = state.cache.read(state.cache_pid, state.store, path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:put, path, value}, _from, state) do
    client_op_id = generate_op_id()
    type = detect_type(value)

    # Optimistic local write
    :ok = state.cache.write(state.cache_pid, state.store, path, value, type, 0)

    # Fire local callbacks
    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :set, value: value,
      committed: false, source: :local, client_op_id: client_op_id
    })

    # Queue for server
    pending = Map.put(state.pending_ops, client_op_id, %{op: :set, path: path, value: value})
    state = %{state | pending_ops: pending}

    # Notify connection to send
    send_to_connection(state.store, %{
      op: :set, path: path, value: value, client_op_id: client_op_id
    })

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, path}, _from, state) do
    client_op_id = generate_op_id()

    state.cache.delete(state.cache_pid, state.store, path)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :delete, value: nil,
      committed: false, source: :local, client_op_id: client_op_id
    })

    pending = Map.put(state.pending_ops, client_op_id, %{op: :delete, path: path})
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, %{op: :delete, path: path, client_op_id: client_op_id})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:merge, path, map}, _from, state) do
    client_op_id = generate_op_id()

    # Optimistic: write each child
    Enum.each(map, fn {key, value} ->
      child_path = "#{path}.#{key}"
      state.cache.write(state.cache_pid, state.store, child_path, value, detect_type(value), 0)
    end)

    dispatch_callbacks(state, path, %{
      store: state.store, path: path, op: :merge, value: map,
      committed: false, source: :local, client_op_id: client_op_id
    })

    pending = Map.put(state.pending_ops, client_op_id, %{op: :merge, path: path, value: map})
    state = %{state | pending_ops: pending}

    send_to_connection(state.store, %{op: :merge, path: path, value: map, client_op_id: client_op_id})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:enum, pattern}, _from, state) do
    results = state.cache.read_all(state.cache_pid, state.store, pattern)
    {:reply, results, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connection: state.status,
      last_store_seq: state.last_store_seq,
      pending_ops: map_size(state.pending_ops)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call({:on, pattern, callback}, _from, state) do
    ref = Dust.CallbackRegistry.register(state.callbacks, state.store, pattern, callback)
    {:reply, ref, state}
  end

  @impl true
  def handle_cast({:server_event, event}, state) do
    client_op_id = event["client_op_id"]
    path = event["path"]
    store_seq = event["store_seq"]
    op = String.to_existing_atom(event["op"])
    value = event["value"]

    # Update cache with canonical state
    case op do
      :set ->
        state.cache.write(state.cache_pid, state.store, path, value, detect_type(value), store_seq)
      :delete ->
        state.cache.delete(state.cache_pid, state.store, path)
      :merge when is_map(value) ->
        Enum.each(value, fn {key, v} ->
          child_path = "#{path}.#{key}"
          state.cache.write(state.cache_pid, state.store, child_path, v, detect_type(v), store_seq)
        end)
    end

    # Reconcile pending ops
    was_pending = Map.has_key?(state.pending_ops, client_op_id)
    pending = Map.delete(state.pending_ops, client_op_id)

    # If this was our own write accepted as-is, don't fire callback again
    unless was_pending do
      dispatch_callbacks(state, path, %{
        store: state.store, path: path, op: op, value: value,
        store_seq: store_seq, committed: true, source: :server,
        device_id: event["device_id"], client_op_id: client_op_id
      })
    end

    state = %{state | pending_ops: pending, last_store_seq: store_seq}
    {:noreply, state}
  end

  defp dispatch_callbacks(state, path, event) do
    callbacks = Dust.CallbackRegistry.match(state.callbacks, state.store, path)
    Enum.each(callbacks, fn callback -> callback.(event) end)
  end

  defp send_to_connection(store, op_attrs) do
    case Registry.lookup(Dust.ConnectionRegistry, store) do
      [{pid, _}] -> send(pid, {:send_write, op_attrs})
      [] -> :ok
    end
  end

  defp generate_op_id do
    "op_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp detect_type(value) when is_map(value), do: "map"
  defp detect_type(value) when is_binary(value), do: "string"
  defp detect_type(value) when is_integer(value), do: "integer"
  defp detect_type(value) when is_float(value), do: "float"
  defp detect_type(value) when is_boolean(value), do: "boolean"
  defp detect_type(nil), do: "null"
  defp detect_type(_), do: "string"
end
```

### Step 5: Implement connection module (placeholder for integration)

`sdk/elixir/lib/dust/connection.ex`:

```elixir
defmodule Dust.Connection do
  @moduledoc """
  WebSocket client that connects to the Dust server.
  Handles hello handshake, store joins, catch-up replay,
  and forwarding writes from SyncEngines.

  Full implementation wired up during integration testing (Task 11).
  """
  use GenServer

  defstruct [:url, :token, :device_id, :stores, :status]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      url: Keyword.fetch!(opts, :url),
      token: Keyword.fetch!(opts, :token),
      device_id: Keyword.get(opts, :device_id, generate_device_id()),
      stores: Keyword.fetch!(opts, :stores),
      status: :disconnected
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:send_write, _op_attrs}, state) do
    # TODO: send via WebSocket in integration task
    {:noreply, state}
  end

  defp generate_device_id do
    "dev_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
```

### Step 6: Implement SDK supervisor and public API

`sdk/elixir/lib/dust/supervisor.ex`:

```elixir
defmodule Dust.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    stores = Keyword.fetch!(opts, :stores)
    cache = Keyword.fetch!(opts, :cache)
    url = Keyword.get(opts, :url, "ws://localhost:7000/ws/sync")
    token = Keyword.get(opts, :token, System.get_env("DUST_API_KEY"))

    engine_children =
      Enum.map(stores, fn store ->
        {Dust.SyncEngine, store: store, cache: cache}
      end)

    children =
      [
        {Registry, keys: :unique, name: Dust.SyncEngineRegistry},
        {Registry, keys: :unique, name: Dust.ConnectionRegistry}
      ] ++ engine_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

`sdk/elixir/lib/dust.ex`:

```elixir
defmodule Dust do
  @moduledoc "Dust SDK — reactive global map client."

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Dust.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  defdelegate get(store, path), to: Dust.SyncEngine
  defdelegate put(store, path, value), to: Dust.SyncEngine
  defdelegate delete(store, path), to: Dust.SyncEngine
  defdelegate merge(store, path, map), to: Dust.SyncEngine
  defdelegate on(store, pattern, callback), to: Dust.SyncEngine
  defdelegate enum(store, pattern), to: Dust.SyncEngine
  defdelegate status(store), to: Dust.SyncEngine
end
```

### Step 7: Write sync engine tests (using memory cache, no server)

`sdk/elixir/test/dust/sync_engine_test.exs`:

```elixir
defmodule Dust.SyncEngineTest do
  use ExUnit.Case

  alias Dust.SyncEngine

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} = SyncEngine.start_link(
      store: "test/store",
      cache: {Dust.Cache.Memory, []}
    )

    :ok
  end

  test "put and get" do
    :ok = SyncEngine.put("test/store", "posts.hello", %{"title" => "Hello"})
    assert {:ok, %{"title" => "Hello"}} = SyncEngine.get("test/store", "posts.hello")
  end

  test "delete" do
    SyncEngine.put("test/store", "x", "value")
    SyncEngine.delete("test/store", "x")
    assert :miss = SyncEngine.get("test/store", "x")
  end

  test "merge updates children" do
    SyncEngine.put("test/store", "settings.theme", "light")
    SyncEngine.merge("test/store", "settings", %{"theme" => "dark", "locale" => "en"})
    assert {:ok, "dark"} = SyncEngine.get("test/store", "settings.theme")
    assert {:ok, "en"} = SyncEngine.get("test/store", "settings.locale")
  end

  test "enum returns matching entries" do
    SyncEngine.put("test/store", "posts.a", "1")
    SyncEngine.put("test/store", "posts.b", "2")
    SyncEngine.put("test/store", "config.x", "3")

    results = SyncEngine.enum("test/store", "posts.*")
    assert length(results) == 2
  end

  test "on fires callback for matching writes" do
    test_pid = self()
    SyncEngine.on("test/store", "posts.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "posts.hello", "value")
    assert_receive {:event, %{path: "posts.hello", committed: false, source: :local}}
  end

  test "on does not fire for non-matching writes" do
    test_pid = self()
    SyncEngine.on("test/store", "posts.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "config.x", "value")
    refute_receive {:event, _}
  end

  test "status reports state" do
    status = SyncEngine.status("test/store")
    assert status.connection == :disconnected
    assert status.last_store_seq == 0
    assert status.pending_ops >= 0
  end
end
```

### Step 8: Run SDK tests

```bash
cd sdk/elixir && mix test
```

### Step 9: Commit

```bash
git add sdk/
git commit -m "feat: add SDK sync engine, callback registry, memory cache, and public API"
```

---

## Task 11: Integration Smoke Tests

End-to-end tests that start a real server, connect SDK clients via WebSocket, and exercise the full sync path. These are the 12 smoke tests from the design doc.

**Files:**
- Create: `server/test/integration/smoke_test.exs`
- Create: `server/test/support/integration_helpers.ex`

### Step 1: Create integration test helpers

`server/test/support/integration_helpers.ex`:

```elixir
defmodule Dust.IntegrationHelpers do
  alias Dust.{Accounts, Stores}

  @doc "Create a user, org, store, and read-write token. Returns a map with all entities."
  def create_test_store(org_slug \\ "test", store_name \\ "blog") do
    {:ok, user} = Accounts.create_user(%{email: "#{org_slug}@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: org_slug, slug: org_slug})
    {:ok, store} = Stores.create_store(org, %{name: store_name})
    {:ok, token} = Stores.create_store_token(store, %{name: "test", read: true, write: true, created_by_id: user.id})

    %{user: user, org: org, store: store, token: token}
  end

  @doc "Connect a Phoenix Channel test client to a store."
  def connect_client(token, store, device_id, last_seq \\ 0) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(DustWeb.StoreSocket, %{
        "token" => token.raw_token,
        "device_id" => device_id,
        "capver" => 1
      })

    {:ok, reply, socket} =
      Phoenix.ChannelTest.subscribe_and_join(
        socket,
        DustWeb.StoreChannel,
        "store:#{store.id}",
        %{"last_store_seq" => last_seq}
      )

    {socket, reply}
  end
end
```

### Step 2: Write the smoke test suite

`server/test/integration/smoke_test.exs`:

```elixir
defmodule Dust.Integration.SmokeTest do
  use Dust.DataCase, async: false
  import Phoenix.ChannelTest
  import Dust.IntegrationHelpers

  # 1. Connect & auth
  describe "connect and auth" do
    test "valid token connects" do
      %{token: token, store: store} = create_test_store()
      {_socket, reply} = connect_client(token, store, "dev_1")
      assert is_integer(reply.store_seq)
    end

    test "invalid token rejects" do
      assert :error =
               Phoenix.ChannelTest.connect(DustWeb.StoreSocket, %{
                 "token" => "dust_tok_invalid",
                 "device_id" => "dev_1",
                 "capver" => 1
               })
    end
  end

  # 2. Basic CRUD
  describe "basic CRUD" do
    test "put, get, merge, delete round-trip" do
      %{token: token, store: store} = create_test_store()
      {socket, _} = connect_client(token, store, "dev_1")

      # Put
      ref = push(socket, "write", %{"op" => "set", "path" => "posts.hello", "value" => %{"title" => "Hello"}, "client_op_id" => "o1"})
      assert_reply ref, :ok, %{store_seq: 1}

      # Verify entry exists
      entry = Dust.Sync.get_entry(store.id, "posts.hello")
      assert entry.value == %{"title" => "Hello"}

      # Merge
      ref = push(socket, "write", %{"op" => "merge", "path" => "posts.hello", "value" => %{"body" => "World"}, "client_op_id" => "o2"})
      assert_reply ref, :ok, %{store_seq: 2}

      assert Dust.Sync.get_entry(store.id, "posts.hello.body").value == %{"_scalar" => "World"}

      # Delete
      ref = push(socket, "write", %{"op" => "delete", "path" => "posts.hello", "value" => nil, "client_op_id" => "o3"})
      assert_reply ref, :ok, %{store_seq: 3}

      assert Dust.Sync.get_entry(store.id, "posts.hello") == nil
    end
  end

  # 3. Two-client sync
  describe "two-client sync" do
    test "client A write appears on client B" do
      %{token: token, store: store} = create_test_store()
      {socket_a, _} = connect_client(token, store, "dev_a")
      {_socket_b, _} = connect_client(token, store, "dev_b")

      push(socket_a, "write", %{"op" => "set", "path" => "x", "value" => "from_a", "client_op_id" => "o1"})

      # Client B should receive the broadcast
      assert_broadcast "event", %{path: "x", op: :set}
    end
  end

  # 4. Optimistic reconciliation
  describe "optimistic reconciliation" do
    test "write gets acknowledged with store_seq" do
      %{token: token, store: store} = create_test_store()
      {socket, _} = connect_client(token, store, "dev_1")

      ref = push(socket, "write", %{"op" => "set", "path" => "x", "value" => "v", "client_op_id" => "my_op"})
      assert_reply ref, :ok, %{store_seq: seq}
      assert seq == 1

      # The broadcast includes client_op_id for reconciliation
      assert_broadcast "event", %{client_op_id: "my_op", store_seq: 1}
    end
  end

  # 5. Conflict: same path
  describe "conflict: same path" do
    test "later store_seq wins" do
      %{token: token, store: store} = create_test_store()
      {socket_a, _} = connect_client(token, store, "dev_a")

      push(socket_a, "write", %{"op" => "set", "path" => "x", "value" => "first", "client_op_id" => "o1"})
      push(socket_a, "write", %{"op" => "set", "path" => "x", "value" => "second", "client_op_id" => "o2"})

      # Wait for processing
      :timer.sleep(50)

      entry = Dust.Sync.get_entry(store.id, "x")
      assert entry.value == %{"_scalar" => "second"}
      assert entry.seq == 2
    end
  end

  # 6. Conflict: ancestor vs descendant
  describe "conflict: ancestor vs descendant" do
    test "set on ancestor removes descendant" do
      %{token: token, store: store} = create_test_store()
      {socket, _} = connect_client(token, store, "dev_1")

      push(socket, "write", %{"op" => "set", "path" => "posts.hello.title", "value" => "Hi", "client_op_id" => "o1"})
      push(socket, "write", %{"op" => "set", "path" => "posts.hello.body", "value" => "Body", "client_op_id" => "o2"})

      :timer.sleep(50)

      # Set ancestor replaces entire subtree
      ref = push(socket, "write", %{"op" => "set", "path" => "posts", "value" => %{"new" => "data"}, "client_op_id" => "o3"})
      assert_reply ref, :ok, _

      :timer.sleep(50)

      assert Dust.Sync.get_entry(store.id, "posts.hello.title") == nil
      assert Dust.Sync.get_entry(store.id, "posts.hello.body") == nil
      assert Dust.Sync.get_entry(store.id, "posts") != nil
    end
  end

  # 7. Conflict: merge vs set
  describe "conflict: merge vs set" do
    test "set after merge replaces everything" do
      %{token: token, store: store} = create_test_store()
      {socket, _} = connect_client(token, store, "dev_1")

      push(socket, "write", %{"op" => "merge", "path" => "settings", "value" => %{"locale" => "en"}, "client_op_id" => "o1"})
      :timer.sleep(50)

      ref = push(socket, "write", %{"op" => "set", "path" => "settings", "value" => %{"theme" => "dark"}, "client_op_id" => "o2"})
      assert_reply ref, :ok, _

      :timer.sleep(50)

      # set replaced the merge — locale is gone
      assert Dust.Sync.get_entry(store.id, "settings.locale") == nil
      assert Dust.Sync.get_entry(store.id, "settings") != nil
    end
  end

  # 8. Catch-up sync
  describe "catch-up sync" do
    test "new client receives all prior ops" do
      %{token: token, store: store} = create_test_store()

      # Write 10 ops directly (no client needed)
      for i <- 1..10 do
        Dust.Sync.write(store.id, %{op: :set, path: "key#{i}", value: "val#{i}", device_id: "d", client_op_id: "o#{i}"})
      end

      # Connect client with last_seq 0 — should get all 10
      {_socket, reply} = connect_client(token, store, "dev_late", 0)
      assert reply.store_seq == 10

      for i <- 1..10 do
        assert_push "event", %{store_seq: ^i}
      end
    end
  end

  # 9. Reconnect catch-up
  describe "reconnect catch-up" do
    test "client catches up from where it left off" do
      %{token: token, store: store} = create_test_store()

      # Write 5 ops
      for i <- 1..5 do
        Dust.Sync.write(store.id, %{op: :set, path: "key#{i}", value: "v#{i}", device_id: "d", client_op_id: "o#{i}"})
      end

      # Client joins at seq 3 — should only get ops 4 and 5
      {_socket, reply} = connect_client(token, store, "dev_recon", 3)
      assert reply.store_seq == 5

      assert_push "event", %{store_seq: 4}
      assert_push "event", %{store_seq: 5}
      refute_push "event", %{store_seq: 1}
    end
  end

  # 10. Glob subscriptions
  describe "glob subscriptions" do
    test "pattern filters events correctly" do
      %{token: token, store: store} = create_test_store()
      {socket, _} = connect_client(token, store, "dev_1")

      # Write to matching and non-matching paths
      push(socket, "write", %{"op" => "set", "path" => "posts.hello", "value" => "v", "client_op_id" => "o1"})
      push(socket, "write", %{"op" => "set", "path" => "posts.hello.title", "value" => "v", "client_op_id" => "o2"})
      push(socket, "write", %{"op" => "set", "path" => "config.x", "value" => "v", "client_op_id" => "o3"})

      # All three broadcast (Channel broadcasts everything for the store)
      assert_broadcast "event", %{path: "posts.hello"}
      assert_broadcast "event", %{path: "posts.hello.title"}
      assert_broadcast "event", %{path: "config.x"}

      # Glob filtering happens in the SDK callback registry (tested in SDK tests)
    end
  end

  # 11. Enum
  describe "enum" do
    test "returns materialized entries matching pattern" do
      %{store: store} = create_test_store()

      Dust.Sync.write(store.id, %{op: :set, path: "posts.a", value: "1", device_id: "d", client_op_id: "o1"})
      Dust.Sync.write(store.id, %{op: :set, path: "posts.b", value: "2", device_id: "d", client_op_id: "o2"})
      Dust.Sync.write(store.id, %{op: :set, path: "config.x", value: "3", device_id: "d", client_op_id: "o3"})

      entries = Dust.Sync.get_all_entries(store.id)
      posts = Enum.filter(entries, &String.starts_with?(&1.path, "posts."))
      assert length(posts) == 2
    end
  end

  # 12. Backpressure — deferred to when the SDK connection is fully wired
end
```

### Step 3: Run smoke tests

```bash
cd server && mix test test/integration/smoke_test.exs
```

Fix any failures. These tests exercise the full server path — Channel → Writer → DB → PubSub → broadcast.

### Step 4: Commit

```bash
git add server/
git commit -m "feat: add integration smoke test suite — 11 scenarios covering sync, conflicts, catch-up"
```

---

## Task 12: Protocol Spec Documents

Write the AsyncAPI definition and sync semantics prose doc.

**Files:**
- Create: `protocol/spec/asyncapi.yaml`
- Create: `protocol/spec/sync-semantics.md`

### Step 1: Write AsyncAPI spec

`protocol/spec/asyncapi.yaml`:

```yaml
asyncapi: 3.0.0
info:
  title: Dust Sync Protocol
  version: 0.1.0
  description: |
    Wire protocol for Dust — a reactive global map.
    Clients connect via WebSocket and sync store state
    using MessagePack or JSON serialization.

servers:
  production:
    host: api.dust.dev
    protocol: wss
    description: Production Dust server
  development:
    host: localhost:7000
    protocol: ws
    description: Local development server

defaultContentType: application/x-msgpack

channels:
  storeSync:
    address: /ws/sync
    description: |
      WebSocket endpoint for store synchronization.
      Supports subprotocols: dust.msgpack (production), dust.json (development).
    messages:
      hello:
        $ref: '#/components/messages/Hello'
      helloResponse:
        $ref: '#/components/messages/HelloResponse'
      join:
        $ref: '#/components/messages/Join'
      write:
        $ref: '#/components/messages/Write'
      event:
        $ref: '#/components/messages/Event'
      error:
        $ref: '#/components/messages/Error'

operations:
  sendHello:
    action: send
    channel:
      $ref: '#/channels/storeSync'
    messages:
      - $ref: '#/channels/storeSync/messages/hello'
    description: Client sends hello to authenticate and negotiate capver.

  receiveHelloResponse:
    action: receive
    channel:
      $ref: '#/channels/storeSync'
    messages:
      - $ref: '#/channels/storeSync/messages/helloResponse'

  sendJoin:
    action: send
    channel:
      $ref: '#/channels/storeSync'
    messages:
      - $ref: '#/channels/storeSync/messages/join'
    description: Client joins a store topic, providing last known store_seq for catch-up.

  sendWrite:
    action: send
    channel:
      $ref: '#/channels/storeSync'
    messages:
      - $ref: '#/channels/storeSync/messages/write'
    description: Client submits a write operation. Server assigns store_seq and echoes to all.

  receiveEvent:
    action: receive
    channel:
      $ref: '#/channels/storeSync'
    messages:
      - $ref: '#/channels/storeSync/messages/event'
    description: Server broadcasts canonical events to all connected clients.

  receiveError:
    action: receive
    channel:
      $ref: '#/channels/storeSync'
    messages:
      - $ref: '#/channels/storeSync/messages/error'

components:
  messages:
    Hello:
      name: hello
      contentType: application/x-msgpack
      payload:
        type: object
        required: [type, capver, device_id, token]
        properties:
          type:
            type: string
            const: hello
          capver:
            type: integer
            description: Client capability version
          device_id:
            type: string
            description: Unique device identifier
          token:
            type: string
            description: Authentication token (dust_tok_...)

    HelloResponse:
      name: hello_response
      payload:
        type: object
        required: [type, capver_min, capver_max, your_capver]
        properties:
          type:
            type: string
            const: hello_response
          capver_min:
            type: integer
          capver_max:
            type: integer
          your_capver:
            type: integer
          stores:
            type: array
            items:
              type: string
            description: Stores this token has access to

    Join:
      name: join
      payload:
        type: object
        required: [type, store, last_store_seq]
        properties:
          type:
            type: string
            const: join
          store:
            type: string
            description: Full store name (org/name) or store ID
          last_store_seq:
            type: integer
            description: Last store_seq the client has seen. Server sends events after this.

    Write:
      name: write
      payload:
        type: object
        required: [type, store, op, path, client_op_id]
        properties:
          type:
            type: string
            const: write
          store:
            type: string
          op:
            type: string
            enum: [set, delete, merge]
          path:
            type: string
            description: Dot-separated path (e.g. posts.hello.title)
          value: {}
          client_op_id:
            type: string
            description: Client-generated ID for optimistic reconciliation

    Event:
      name: event
      payload:
        type: object
        required: [type, store, store_seq, op, path, device_id, client_op_id]
        properties:
          type:
            type: string
            const: event
          store:
            type: string
          store_seq:
            type: integer
            description: Monotonically increasing server-assigned sequence number
          op:
            type: string
            enum: [set, delete, merge]
          path:
            type: string
          value: {}
          device_id:
            type: string
          client_op_id:
            type: string

    Error:
      name: error
      payload:
        type: object
        required: [type, code, message]
        properties:
          type:
            type: string
            const: error
          code:
            type: string
          message:
            type: string
```

### Step 2: Write sync semantics doc

`protocol/spec/sync-semantics.md`:

```markdown
# Dust Sync Semantics

Companion to `asyncapi.yaml`. Covers behavioral semantics that the schema cannot express.

## Server-Authoritative Ordering

Each store has a single monotonically increasing `store_seq`. The server assigns it.
Clients never generate `store_seq` — they generate `client_op_id` for reconciliation.

One write at a time per store. The server processes writes sequentially.

## Conflict Resolution

### Path Scope Rules

- **Unrelated paths** (neither is ancestor of the other): both writes survive.
- **Same path**: later `store_seq` replaces the earlier value.
- **Ancestor vs descendant**: `set` or `delete` on ancestor replaces the subtree.
  A later descendant write recreates under that path.
- **`merge(path, map)`**: updates only named child keys. Unmentioned siblings survive.
- **`merge` vs `set` on the same path**: later committed op wins.

### Path Syntax

Paths are dot-separated segments: `posts.hello.title`.

- Segments are non-empty strings.
- Path `a` is ancestor of `a.b` and `a.b.c`.
- Path `a` is not ancestor of `ab` or `a` itself.

## Optimistic Write Lifecycle

1. Client writes locally, generates `client_op_id`, fires local callbacks with `committed: false`.
2. Client sends write to server.
3. Server assigns `store_seq`, persists, broadcasts event to all clients.
4. Origin client matches `client_op_id`:
   - Accepted as-is → mark committed, no second callback.
   - Corrected → apply canonical state, fire callback with `correction_for`.
   - Rejected → roll back local state, fire error callback.

## Catch-Up Sync

1. Client sends `last_store_seq` on join.
2. Server responds with all events where `store_seq > last_store_seq`, in order.
3. If client is behind compaction point, server sends snapshot at `snapshot_seq`,
   then the op tail after `snapshot_seq`.

## Callback Semantics

Subscriptions are live, not durable. Not replayed across restarts.

Recovery pattern:
1. `enum` on boot to build current state.
2. `on` to receive live changes.
3. Repeat on restart.

### Glob Pattern Matching

- `*` matches exactly one path segment.
- `**` matches one or more path segments.
- Exact paths match exactly.

### Backpressure

Each subscription has a bounded queue (default 1,000 events).
If exceeded, subscription is dropped and `resync_required` is raised.
Store sync continues — one slow subscriber does not stall the store.

## Capability Versioning

Single integer, sent in hello. MVP ships with `capver = 1`.
Server responds with `capver_min` and `capver_max`.
If client capver is outside the range, connection is rejected.

## Wire Encoding

Two subprotocols:
- `dust.msgpack` — MessagePack encoding. Production default.
- `dust.json` — JSON encoding. Development and debugging.

Both encode the same message shapes defined in `asyncapi.yaml`.
```

### Step 3: Commit

```bash
git add protocol/spec/
git commit -m "feat: add protocol spec — AsyncAPI definition and sync semantics doc"
```

---

## Task Summary

| Task | Description | Depends on |
|------|-------------|------------|
| 1 | Protocol library (path, glob, codec, ops) | — |
| 2 | Server scaffolding (Phoenix, UUIDv7, ports) | 1 |
| 3 | Dual endpoints (AdminWeb + DustWeb) | 2 |
| 4 | Accounts (users, orgs, memberships) | 2 |
| 5 | Stores, tokens, devices | 4 |
| 6 | Sync engine tables | 5 |
| 7 | Store Writer GenServer + conflict resolution | 6 |
| 8 | Phoenix Channel + WebSocket sync | 7 |
| 9 | SDK scaffolding + cache adapter | 1 |
| 10 | SDK sync engine + connection + public API | 9 |
| 11 | Integration smoke tests | 8, 10 |
| 12 | Protocol spec documents | — |

**Parallelizable:** Tasks 3 and 4 can run in parallel. Tasks 9-10 (SDK) can run in parallel with Tasks 5-8 (server internals). Task 12 can run anytime.
