# Dust Phase 2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add the user-facing dashboard, MCP endpoint, audit log, rollback, extended types (counters, sets, decimals, datetimes), and file support.

**Architecture:** Builds on the Phase 1 server (Phoenix), SDK (Elixir), and protocol library. Dashboard uses Inertia/React on `DustWeb` (port 7000) with shadcn/ui components, following patterns from the `root` project at `/Users/james/Desktop/elixir/root`. MCP endpoint uses GenMCP (`gen_mcp`). Extended types add new conflict resolution rules to the Writer and new ops to the protocol.

**Tech Stack:** Phoenix 1.8, Inertia 2.0, React 19, Vite 6, Tailwind v4, shadcn/ui (Radix + CVA), Lucide icons, GenMCP, WorkOS AuthKit

**Reference docs:**
- Design: `docs/plans/2026-03-26-dust-design-v4.md`
- Phase 1 design: `docs/plans/2026-03-28-dust-phase1-design.md`
- Phoenix patterns: `/Users/james/Desktop/elixir/agents/PHOENIX_ARCHITECTURE_GUIDE.md` (Sections 6-8)
- UI patterns: `/Users/james/Desktop/elixir/root` (Shell layout, components, Inertia setup)

---

## Task 1: Vite + Inertia + React Setup

Set up the frontend build pipeline on DustWeb following Section 6 of the Phoenix Architecture Guide and Root's exact patterns.

**Files:**
- Create: `server/assets/vite.config.mjs`
- Create: `server/assets/package.json`
- Create: `server/assets/js/app.js`
- Create: `server/assets/js/admin.js`
- Create: `server/assets/css/app.css`
- Create: `server/assets/css/admin.css`
- Create: `server/assets/tsconfig.json`
- Modify: `server/config/config.exs` (add `:inertia` config)
- Modify: `server/lib/dust_web/endpoint.ex` (add Vite watcher, Inertia.Plug)
- Modify: `server/lib/dust_web.ex` (add Inertia imports)
- Modify: `server/lib/dust_web/components/layouts/root.html.heex`
- Modify: `server/mix.exs` (ensure phoenix_vite, inertia deps)

### Step 1: Create package.json

`server/assets/package.json` — match Root's deps:

```json
{
  "dependencies": {
    "@inertiajs/react": "^2.2.0",
    "@radix-ui/react-dialog": "^1.1.0",
    "@radix-ui/react-dropdown-menu": "^2.1.0",
    "@radix-ui/react-label": "^2.1.0",
    "@radix-ui/react-select": "^2.1.0",
    "@radix-ui/react-tabs": "^1.1.0",
    "@radix-ui/react-tooltip": "^1.1.0",
    "axios": "^1.7.0",
    "class-variance-authority": "^0.7.0",
    "clsx": "^2.1.0",
    "lucide-react": "^0.500.0",
    "phoenix": "file:../deps/phoenix",
    "phoenix_html": "file:../deps/phoenix_html",
    "phoenix_live_view": "file:../deps/phoenix_live_view",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "sonner": "^2.0.0",
    "tailwind-merge": "^3.0.0"
  },
  "devDependencies": {
    "@tailwindcss/vite": "^4.1.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "@vitejs/plugin-react": "^4.3.0",
    "phoenix_vite": "file:../deps/phoenix_vite",
    "tailwindcss": "^4.1.0",
    "typescript": "^5.7.0",
    "vite": "^6.0.0"
  }
}
```

### Step 2: Create vite.config.mjs

`server/assets/vite.config.mjs`:

```javascript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { phoenixVitePlugin } from "phoenix_vite";
import path from "path";

export default defineConfig({
  server: {
    port: 5175,
    strictPort: true,
    cors: {
      origin: ["http://localhost:7000", "http://localhost:7001"],
    },
  },
  build: {
    manifest: true,
    rollupOptions: {
      input: ["js/app.js", "js/admin.js", "css/app.css", "css/admin.css"],
    },
    outDir: "../priv/static",
    emptyOutDir: true,
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./js"),
    },
  },
  plugins: [
    react(),
    tailwindcss(),
    phoenixVitePlugin({ pattern: /\.(ex|heex)$/ }),
  ],
});
```

### Step 3: Create entry points

`server/assets/js/app.js` — follow Root's pattern:

```javascript
import "phoenix_html";
import { createInertiaApp } from "@inertiajs/react";
import { createRoot } from "react-dom/client";
import React from "react";
import axios from "axios";

const csrfToken = document
  .querySelector('meta[name="csrf-token"]')
  ?.getAttribute("content");
axios.defaults.headers.common["X-CSRF-Token"] = csrfToken;

createInertiaApp({
  title: (title) => (title ? `${title} — Dust` : "Dust"),
  resolve: async (name) => {
    const pages = import.meta.glob("./pages/**/*.tsx", { eager: true });
    const page = pages[`./pages/${name}.tsx`];
    if (!page) {
      throw new Error(`Page not found: ${name}. Looking for ./pages/${name}.tsx`);
    }
    const component = page.default || page;
    // Support persistent layouts
    if (!component.layout) {
      const { Shell } = await import("./layouts/Shell");
      component.layout = (page) => React.createElement(Shell, null, page);
    }
    return component;
  },
  setup({ el, App, props }) {
    createRoot(el).render(React.createElement(App, props));
  },
  progress: { color: "#4B5563" },
});
```

`server/assets/js/admin.js` — LiveView entry (same as Phase 1 plan).

`server/assets/css/app.css` — Tailwind with shadcn/ui theme variables. Copy Root's CSS variable structure (OkLch color space, semantic tokens for background/foreground/muted/accent/etc.). Use a neutral color palette.

`server/assets/css/admin.css` — minimal Tailwind for admin LiveView.

### Step 4: Configure Inertia + Vite in Elixir

`server/config/config.exs` — add:
```elixir
config :inertia,
  endpoint: DustWeb.Endpoint,
  static_paths: ["/.vite/manifest.json"],
  ssr: false,
  raise_on_ssr_failure: true
```

### Step 5: Update DustWeb endpoint

Add Vite watcher to `server/config/dev.exs` for DustWeb.Endpoint:
```elixir
watchers: [
  node: ["node_modules/.bin/vite", "dev", cd: Path.expand("../assets", __DIR__)]
]
```

Add `plug Inertia.Plug` to `server/lib/dust_web/endpoint.ex` before the router plug.

### Step 6: Update DustWeb module

Add `import Inertia.Controller` to the controller macro in `server/lib/dust_web.ex`. Add `import Inertia.HTML` to the html helpers.

### Step 7: Update root layout

`server/lib/dust_web/components/layouts/root.html.heex` — add Inertia head, CSRF meta, and PhoenixVite.Components.assets for `js/app.js` and `css/app.css`.

### Step 8: Create tsconfig.json

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "esModuleInterop": true,
    "baseUrl": ".",
    "paths": { "@/*": ["./js/*"] }
  },
  "include": ["js/**/*"]
}
```

### Step 9: Install deps and verify

```bash
cd server/assets && npm install && cd ..
mix deps.get
```

Verify Vite starts and serves the dev bundle.

### Step 10: Commit

```bash
git add server/
git commit -m "feat: set up Vite + Inertia + React with Tailwind v4 and shadcn/ui theme"
```

---

## Task 2: Shadcn/UI Base Components

Create the shared UI component library following Root's patterns.

**Files:**
- Create: `server/assets/js/lib/utils.ts` (cn helper)
- Create: `server/assets/js/components/ui/Button.tsx`
- Create: `server/assets/js/components/ui/Card.tsx`
- Create: `server/assets/js/components/ui/Table.tsx`
- Create: `server/assets/js/components/ui/Badge.tsx`
- Create: `server/assets/js/components/ui/Input.tsx`
- Create: `server/assets/js/components/ui/Label.tsx`
- Create: `server/assets/js/components/ui/Dialog.tsx`
- Create: `server/assets/js/components/ui/DropdownMenu.tsx`
- Create: `server/assets/js/components/ui/Select.tsx`
- Create: `server/assets/js/components/ui/Tabs.tsx`
- Create: `server/assets/js/components/ui/Tooltip.tsx`
- Create: `server/assets/js/components/ui/Toaster.tsx`

### Step 1: Create utils

`server/assets/js/lib/utils.ts`:
```typescript
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
```

### Step 2: Create each component

Follow the standard shadcn/ui component patterns (Radix primitives + CVA + `cn`). Reference Root's implementations at `/Users/james/Desktop/elixir/root/assets/js/components/ui/` for exact styling.

Key components to match Root:
- **Button** — variants: default, destructive, outline, secondary, ghost, link. Sizes: default, sm, lg, icon.
- **Card** — Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter.
- **Table** — Table, TableHeader, TableBody, TableRow, TableHead, TableCell. Include `TableActionsCell` variant from Root.
- **Badge** — default, secondary, destructive, outline variants.
- **Dialog** — Radix Dialog with overlay, content, header, footer.
- **DropdownMenu** — Radix DropdownMenu with all sub-components.
- **Toaster** — Sonner integration.

### Step 3: Commit

```bash
git add server/assets/
git commit -m "feat: add shadcn/ui base component library"
```

---

## Task 3: WorkOS Auth Flow

Implement login/logout using WorkOS AuthKit, following Section 8 of the Phoenix Architecture Guide.

**Files:**
- Create: `server/lib/dust_web/controllers/workos_auth_controller.ex`
- Create: `server/lib/dust_web/plugs/auth.ex`
- Create: `server/lib/dust_web/plugs/inertia_share.ex`
- Modify: `server/lib/dust_web/router.ex` (auth routes, pipelines)
- Modify: `server/config/config.exs` (WorkOS config)
- Modify: `server/config/runtime.exs` (WorkOS env vars)
- Create: `server/assets/js/pages/Auth/Login.tsx`
- Test: `server/test/dust_web/controllers/workos_auth_controller_test.exs`

### Step 1: Configure WorkOS

Add to `server/config/config.exs`:
```elixir
config :workos, WorkOS.Client,
  api_key: System.get_env("WORKOS_API_KEY"),
  client_id: System.get_env("WORKOS_CLIENT_ID")
```

### Step 2: Create auth controller

`server/lib/dust_web/controllers/workos_auth_controller.ex` — follow the architecture guide Section 8c:
- `authorize/2` — redirect to WorkOS AuthKit login
- `callback/2` — exchange code, find-or-create user, create session, redirect to dashboard
- `logout/2` — clear session, redirect to login

### Step 3: Create auth plugs

`server/lib/dust_web/plugs/auth.ex`:
- `fetch_current_scope_for_user/2` — read session token, load user + orgs, build Scope
- `require_authenticated_user/2` — redirect to login if no scope
- `assign_org_to_scope/2` — resolve org from URL param or session

### Step 4: Create InertiaShare plug

`server/lib/dust_web/plugs/inertia_share.ex` — following Root's `inertia_helpers.ex`:
```elixir
conn
|> assign_prop(:current_user, serialize_user(scope))
|> assign_prop(:current_organization, serialize_org(scope))
|> assign_prop(:user_organizations, serialize_user_orgs(scope))
|> assign_prop(:flash, %{info: get_flash(conn, :info), error: get_flash(conn, :error)})
```

### Step 5: Update router

```elixir
pipeline :browser do
  # ... existing plugs
  plug :fetch_current_scope_for_user
  plug DustWeb.Plugs.InertiaShare
  plug Inertia.Plug
end

scope "/auth", DustWeb do
  pipe_through :browser
  get "/login", WorkOSAuthController, :authorize
  get "/callback", WorkOSAuthController, :callback
  delete "/logout", WorkOSAuthController, :logout
end

scope "/", DustWeb do
  pipe_through [:browser, :require_authenticated_user]
  # Dashboard routes go here (Task 5)
end
```

### Step 6: Create login page

`server/assets/js/pages/Auth/Login.tsx` — minimal branded login page with "Sign in with WorkOS" button.

### Step 7: Write tests and commit

```bash
git commit -m "feat: add WorkOS auth flow with session management and InertiaShare"
```

---

## Task 4: Shell Layout + Navigation

Create the main app shell following Root's Shell.tsx pattern.

**Files:**
- Create: `server/assets/js/layouts/Shell.tsx`
- Create: `server/assets/js/components/Sidebar.tsx`
- Create: `server/assets/js/components/UserMenu.tsx`
- Create: `server/assets/js/components/OrganizationSwitcher.tsx`
- Create: `server/assets/js/types.ts` (SharedProps TypeScript types)

### Step 1: Define shared types

`server/assets/js/types.ts`:
```typescript
export interface User {
  id: string;
  email: string;
  first_name: string | null;
  last_name: string | null;
}

export interface Organization {
  id: string;
  name: string;
  slug: string;
}

export interface SharedProps {
  current_user: User | null;
  current_organization: Organization | null;
  user_organizations: Organization[];
  flash: { info: string | null; error: string | null };
}
```

### Step 2: Create Shell layout

`server/assets/js/layouts/Shell.tsx` — following Root's pattern:
- Fixed left sidebar (w-64) with org switcher at top
- Navigation sections: **Stores**, **Tokens**, **Devices**, **Settings**
- Each nav item: Lucide icon + label, active state highlight
- Top bar with user menu (dropdown with profile + logout)
- Mobile: hamburger menu, sidebar as overlay
- Uses `usePage<SharedProps>().props` for user/org data
- Links use Inertia's `<Link>` component

### Step 3: Create OrganizationSwitcher

Dropdown that lists `user_organizations`, switches on selection (navigates to `/{org_slug}/...`).

### Step 4: Create UserMenu

Dropdown with user email, profile link, and logout button (Inertia `router.delete("/auth/logout")`).

### Step 5: Commit

```bash
git commit -m "feat: add Shell layout with sidebar navigation, org switcher, and user menu"
```

---

## Task 5: Dashboard Pages

Build the core pages for store and token management.

**Files:**
- Create: `server/assets/js/pages/Dashboard.tsx`
- Create: `server/assets/js/pages/Stores/Index.tsx`
- Create: `server/assets/js/pages/Stores/Show.tsx`
- Create: `server/assets/js/pages/Stores/Create.tsx`
- Create: `server/assets/js/pages/Tokens/Index.tsx`
- Create: `server/assets/js/pages/Tokens/Create.tsx`
- Create: `server/assets/js/pages/Settings/Index.tsx`
- Create: `server/lib/dust_web/controllers/dashboard_controller.ex`
- Create: `server/lib/dust_web/controllers/store_controller.ex`
- Create: `server/lib/dust_web/controllers/token_controller.ex`
- Create: `server/lib/dust_web/controllers/settings_controller.ex`
- Modify: `server/lib/dust_web/router.ex` (add resource routes)

### Step 1: Add routes

```elixir
scope "/:org", DustWeb do
  pipe_through [:browser, :require_authenticated_user, :assign_org_to_scope]

  get "/", DashboardController, :index
  resources "/stores", StoreController, only: [:index, :show, :new, :create]
  resources "/tokens", TokenController, only: [:index, :new, :create, :delete]
  get "/settings", SettingsController, :index
end
```

### Step 2: Create Dashboard page

`server/assets/js/pages/Dashboard.tsx`:
- Welcome message
- Summary cards: total stores, total keys, connected devices
- Quick actions: create store, create token

`server/lib/dust_web/controllers/dashboard_controller.ex`:
```elixir
def index(conn, _params) do
  scope = conn.assigns.current_scope
  stats = Dust.Stores.get_org_stats(scope.organization)

  conn
  |> assign(:page_title, "Dashboard")
  |> render_inertia("Dashboard", %{stats: stats})
end
```

### Step 3: Create Stores pages

**Stores/Index.tsx** — table of stores with columns: Name (as `{org.slug}/{store.name}`), Status (badge), Keys (count), Created. Row click navigates to store detail. "Create Store" button top-right.

**Stores/Show.tsx** — store detail with tabs:
- **Data** tab: tree view of paths and values from materialized `store_entries`. Shows path, value (truncated), type, seq. Monospace font for paths.
- **Op Log** tab: recent operations from `store_ops`. Shows store_seq, op (badge), path, device_id, timestamp.
- **Devices** tab: connected devices for this store with last_seen_at.

**Stores/Create.tsx** — form with store name input. Auto-prefixes with org slug in preview.

Backend controllers fetch data from `Dust.Stores` and `Dust.Sync` contexts.

### Step 4: Create Tokens pages

**Tokens/Index.tsx** — table of tokens: Name, Store, Permissions (read/write badges), Created, Last Used, Actions (revoke button).

**Tokens/Create.tsx** — form: name, select store, checkboxes for read/write, optional expiry. On create, show the raw token once with copy button (it's never shown again).

### Step 5: Create Settings page

**Settings/Index.tsx** — org name/slug display, members list with roles. Minimal for now.

### Step 6: Add necessary context functions

Add to `Dust.Stores`:
- `list_stores(organization)` — all stores for an org
- `get_org_stats(organization)` — store count, total key count, device count
- `list_store_tokens(store)` — all tokens for a store
- `list_org_tokens(organization)` — all tokens across org stores
- `revoke_token(token_id)` — soft-delete a token

Add to `Dust.Sync`:
- `get_entries_page(store_id, opts)` — paginated entries for data browser
- `get_ops_page(store_id, opts)` — paginated ops for log viewer

### Step 7: Write controller tests and commit

```bash
git commit -m "feat: add dashboard, stores, tokens, and settings pages"
```

---

## Task 6: MCP Endpoint

Add a GenMCP endpoint to the server, exposing Dust tools for AI agents.

**Files:**
- Create: `server/lib/dust_web/mcp_transport.ex`
- Create: `server/lib/dust_web/mcp_router.ex`
- Create: `server/lib/dust/mcp/tools/dust_get.ex`
- Create: `server/lib/dust/mcp/tools/dust_put.ex`
- Create: `server/lib/dust/mcp/tools/dust_merge.ex`
- Create: `server/lib/dust/mcp/tools/dust_delete.ex`
- Create: `server/lib/dust/mcp/tools/dust_enum.ex`
- Create: `server/lib/dust/mcp/tools/dust_stores.ex`
- Create: `server/lib/dust/mcp/tools/dust_status.ex`
- Modify: `server/lib/dust_web/router.ex` (add MCP scope)
- Modify: `server/lib/dust_web/endpoint.ex` (or create separate MCP endpoint)
- Test: `server/test/dust/mcp/tools_test.exs`

### Step 1: Create MCP transport

Follow Section 10d of the Architecture Guide:

`server/lib/dust_web/mcp_transport.ex`:
```elixir
defmodule DustWeb.MCPTransport do
  use Plug.Router

  plug :match
  plug :copy_opts_to_assign, :gen_mcp_streamable_http_opts
  plug :dispatch

  post "/", do: GenMCP.Transport.StreamableHTTP.Impl.handle_post(conn)
  delete "/", do: GenMCP.Transport.StreamableHTTP.Impl.handle_delete(conn)
  get "/", do: GenMCP.Transport.StreamableHTTP.Impl.handle_get(conn)

  defp copy_opts_to_assign(conn, key), do: assign(conn, key, conn.private[:plug_route_opts])
end
```

### Step 2: Create MCP auth pipeline

Add an `:mcp` pipeline to the router that authenticates via Bearer token (same `dust_tok_` tokens):

```elixir
pipeline :mcp do
  plug :accepts, ["json"]
  plug DustWeb.Plugs.MCPAuth
end
```

`DustWeb.Plugs.MCPAuth` reads the `Authorization: Bearer dust_tok_...` header, calls `Dust.Stores.authenticate_token/1`, and assigns the scope.

### Step 3: Wire MCP into router

```elixir
scope "/mcp" do
  pipe_through :mcp

  forward "/", DustWeb.MCPTransport,
    server: GenMCP.Suite,
    server_name: "Dust",
    server_version: "0.1.0",
    copy_assigns: [:store_token],
    tools: [
      Dust.MCP.Tools.DustGet,
      Dust.MCP.Tools.DustPut,
      Dust.MCP.Tools.DustMerge,
      Dust.MCP.Tools.DustDelete,
      Dust.MCP.Tools.DustEnum,
      Dust.MCP.Tools.DustStores,
      Dust.MCP.Tools.DustStatus
    ]
end
```

### Step 4: Implement tools

Each tool follows the GenMCP.Suite.Tool pattern from Section 10f.

Example — `server/lib/dust/mcp/tools/dust_get.ex`:
```elixir
defmodule Dust.MCP.Tools.DustGet do
  use GenMCP.Suite.Tool,
    name: "dust_get",
    title: "Get Value",
    description: "Read the value at a path in a store.",
    input_schema: %{
      type: :object,
      required: ["store", "path"],
      properties: %{
        store: %{type: :string, description: "Full store name (org/name)"},
        path: %{type: :string, description: "Dot-separated path"}
      }
    },
    annotations: %{readOnlyHint: true}

  alias GenMCP.Protocol, as: MCP

  @impl true
  def call(req, channel, _arg) do
    store_name = req["store"]
    path = req["path"]

    case resolve_and_read(store_name, path) do
      {:ok, value} ->
        {:result, MCP.call_tool_result(text: Jason.encode!(value)), channel}
      {:error, reason} ->
        {:error, to_string(reason), channel}
    end
  end

  defp resolve_and_read(store_name, path) do
    case Dust.Stores.get_store_by_full_name(store_name) do
      nil -> {:error, :store_not_found}
      store ->
        case Dust.Sync.get_entry(store.id, path) do
          nil -> {:error, :not_found}
          entry -> {:ok, entry.value}
        end
    end
  end
end
```

Implement all 7 tools similarly:
- `dust_put` — calls `Dust.Sync.write/2` with `:set`
- `dust_merge` — calls `Dust.Sync.write/2` with `:merge`
- `dust_delete` — calls `Dust.Sync.write/2` with `:delete`
- `dust_enum` — calls `Dust.Sync.get_all_entries/1` with glob filter
- `dust_stores` — lists stores for the token's org
- `dust_status` — returns store sync status (current_seq, entry count)

### Step 5: Write tests and commit

Test each tool by calling it directly (no HTTP needed — GenMCP tools are just modules).

```bash
git commit -m "feat: add MCP endpoint with GenMCP tools for store operations"
```

---

## Task 7: Audit Log

Read API over the existing `store_ops` table + UI page.

**Files:**
- Create: `server/lib/dust/sync/audit.ex`
- Create: `server/lib/dust_web/controllers/audit_controller.ex`
- Create: `server/assets/js/pages/Stores/AuditLog.tsx`
- Create: `server/lib/dust/mcp/tools/dust_log.ex`
- Modify: `server/lib/dust_web/router.ex`
- Test: `server/test/dust/sync/audit_test.exs`

### Step 1: Create audit context

`server/lib/dust/sync/audit.ex`:
```elixir
defmodule Dust.Sync.Audit do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Sync.StoreOp

  def query_ops(store_id, opts \\ []) do
    base = from(o in StoreOp, where: o.store_id == ^store_id, order_by: [desc: o.store_seq])

    base
    |> maybe_filter_path(opts[:path])
    |> maybe_filter_device(opts[:device_id])
    |> maybe_filter_op(opts[:op])
    |> maybe_filter_since(opts[:since])
    |> limit_results(opts[:limit] || 50)
    |> Repo.all()
  end

  defp maybe_filter_path(query, nil), do: query
  defp maybe_filter_path(query, pattern) do
    # If pattern contains * or **, filter in Elixir after fetch
    # If exact path, filter in SQL
    if String.contains?(pattern, "*") do
      query
    else
      from(o in query, where: o.path == ^pattern)
    end
  end

  defp maybe_filter_device(query, nil), do: query
  defp maybe_filter_device(query, device_id), do: from(o in query, where: o.device_id == ^device_id)

  defp maybe_filter_op(query, nil), do: query
  defp maybe_filter_op(query, op), do: from(o in query, where: o.op == ^op)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: from(o in query, where: o.inserted_at >= ^since)

  defp limit_results(query, limit), do: from(o in query, limit: ^limit)
end
```

### Step 2: Create audit controller + page

Expose the op log as a paginated Inertia page at `/:org/stores/:id/log`.

### Step 3: Add MCP tool

`dust_log` tool wraps `Dust.Sync.Audit.query_ops/2`.

### Step 4: Write tests and commit

```bash
git commit -m "feat: add audit log API, UI page, and MCP tool"
```

---

## Task 8: Counter and Set Types

Add counter (additive merge) and set (union + add-wins) types to the protocol, server, and SDK.

**Files:**
- Modify: `protocol/elixir/lib/dust_protocol/op.ex` (add :increment, :add, :remove)
- Modify: `server/lib/dust/sync/writer.ex` (counter + set conflict resolution)
- Modify: `server/lib/dust/sync/store_entry.ex` (type handling)
- Modify: `server/lib/dust_web/channels/store_channel.ex` (new ops)
- Modify: `sdk/elixir/lib/dust/sync_engine.ex` (new public API)
- Modify: `sdk/elixir/lib/dust.ex` (new delegates)
- Test: `server/test/dust/sync/counter_test.exs`
- Test: `server/test/dust/sync/set_test.exs`
- Test: `server/test/integration/types_test.exs`

### Step 1: Extend protocol ops

Add to `DustProtocol.Op`:
```elixir
@all_ops [:set, :delete, :merge, :increment, :add, :remove]
```

### Step 2: Add counter conflict resolution to Writer

Counter wire format: `increment(path, delta)` sends `delta` as the value. Server applies: `current_value + delta`.

In `apply_to_entries`:
```elixir
defp apply_to_entries(store_id, seq, %{op: :increment, path: path, value: delta}) do
  # Read current value, add delta, upsert
  current = get_current_counter_value(store_id, path)
  new_value = current + delta

  Repo.insert!(
    %StoreEntry{store_id: store_id, path: path, value: wrap_value(new_value), type: "counter", seq: seq},
    on_conflict: [set: [value: wrap_value(new_value), type: "counter", seq: seq]],
    conflict_target: [:store_id, :path]
  )
end

defp get_current_counter_value(store_id, path) do
  case Repo.get_by(StoreEntry, store_id: store_id, path: path) do
    nil -> 0
    entry -> unwrap_scalar(entry.value)
  end
end
```

### Step 3: Add set conflict resolution to Writer

Set operations: `add(path, member)` and `remove(path, member)`.

In `apply_to_entries`:
```elixir
defp apply_to_entries(store_id, seq, %{op: :add, path: path, value: member}) do
  current = get_current_set_value(store_id, path)
  new_set = MapSet.put(current, member)

  Repo.insert!(
    %StoreEntry{store_id: store_id, path: path, value: wrap_value(MapSet.to_list(new_set)), type: "set", seq: seq},
    on_conflict: [set: [value: wrap_value(MapSet.to_list(new_set)), type: "set", seq: seq]],
    conflict_target: [:store_id, :path]
  )
end

defp apply_to_entries(store_id, seq, %{op: :remove, path: path, value: member}) do
  current = get_current_set_value(store_id, path)
  new_set = MapSet.delete(current, member)

  Repo.insert!(
    %StoreEntry{store_id: store_id, path: path, value: wrap_value(MapSet.to_list(new_set)), type: "set", seq: seq},
    on_conflict: [set: [value: wrap_value(MapSet.to_list(new_set)), type: "set", seq: seq]],
    conflict_target: [:store_id, :path]
  )
end
```

### Step 4: Update Channel to accept new ops

Add `"increment"`, `"add"`, `"remove"` to `@valid_ops`. No new validation needed beyond what exists.

### Step 5: Add SDK public API

```elixir
# In Dust module:
defdelegate increment(store, path, delta \\ 1), to: Dust.SyncEngine
defdelegate add(store, path, member), to: Dust.SyncEngine
defdelegate remove(store, path, member), to: Dust.SyncEngine
```

Add corresponding `handle_call` clauses in SyncEngine.

### Step 6: Write tests

Counter tests: increment creates counter, sequential increments accumulate, concurrent increments sum (via two channel clients), `set` on counter path resets it.

Set tests: add creates set, add is idempotent, remove deletes member, concurrent adds both survive, `set` on set path replaces it.

### Step 7: Add MCP tools

`dust_increment`, `dust_add`, `dust_remove`.

### Step 8: Commit

```bash
git commit -m "feat: add counter and set types with additive and union merge"
```

---

## Task 9: Decimal and DateTime Types

Add decimal and datetime as typed values that serialize/deserialize correctly across the wire.

**Files:**
- Modify: `protocol/elixir/lib/dust_protocol/codec.ex` (ext type encoding)
- Modify: `server/lib/dust/sync/writer.ex` (type detection)
- Modify: `sdk/elixir/lib/dust/sync_engine.ex` (type detection)
- Test: `server/test/dust/sync/typed_values_test.exs`

### Step 1: Extend type detection

In both Writer and SyncEngine `detect_type`:
```elixir
defp detect_type(%Decimal{}), do: "decimal"
defp detect_type(%DateTime{}), do: "datetime"
```

### Step 2: Wire serialization

Decimals serialize as string representation. DateTimes serialize as RFC 3339 strings. Both stored as `%{"_scalar" => "value", "_type" => "decimal"}` in jsonb for lossless round-tripping.

### Step 3: Update unwrap_value

Unwrap typed scalars back to their native types:
```elixir
defp unwrap_value(%{"_scalar" => v, "_type" => "decimal"}), do: Decimal.new(v)
defp unwrap_value(%{"_scalar" => v, "_type" => "datetime"}), do: DateTime.from_iso8601(v) |> elem(1)
```

### Step 4: Write tests and commit

```bash
git commit -m "feat: add decimal and datetime type support with lossless serialization"
```

---

## Task 10: Rollback

Implement path-level and store-level rollback.

**Files:**
- Create: `server/lib/dust/sync/rollback.ex`
- Create: `server/lib/dust/mcp/tools/dust_rollback.ex`
- Modify: `server/lib/dust_web/channels/store_channel.ex` (rollback op)
- Modify: `sdk/elixir/lib/dust.ex` (rollback API)
- Test: `server/test/dust/sync/rollback_test.exs`

### Step 1: Implement rollback logic

`server/lib/dust/sync/rollback.ex`:

**Path-level rollback** (`rollback(store_id, path, to_seq)`):
1. Find the value at `path` at the given `store_seq` by scanning `store_ops` backwards.
2. Write a new `:set` op with that historical value (or `:delete` if the path didn't exist at that seq).
3. The rollback is a forward operation — it creates new ops at the current seq.

**Store-level rollback** (`rollback(store_id, to_seq)`):
1. Compute the store state at `to_seq` by replaying ops from the beginning (or from the nearest snapshot).
2. Diff against current state.
3. Write new ops that bring current state back to match the historical state.

### Step 2: Add rollback check

Rollback only works within the retention window. If `to_seq` is before the earliest available op (after compaction), return `{:error, :beyond_retention}`.

### Step 3: Add Channel, MCP, and SDK support

Expose via Channel (new `handle_in("rollback", ...)`), MCP tool (`dust_rollback`), and SDK (`Dust.rollback/3`).

### Step 4: Write tests and commit

```bash
git commit -m "feat: add path-level and store-level rollback"
```

---

## Task 11: File Type — Server Storage

Add S3-backed file storage with content-addressed blobs.

**Files:**
- Create: `server/lib/dust/files.ex` (file storage context)
- Create: `server/lib/dust/files/blob.ex` (blob schema)
- Create: `server/priv/repo/migrations/*_create_blobs.exs`
- Modify: `server/lib/dust/sync/writer.ex` (put_file op)
- Modify: `server/config/config.exs` (S3 config)
- Modify: `server/mix.exs` (add ex_aws deps)
- Test: `server/test/dust/files_test.exs`

### Step 1: Add S3 dependencies

```elixir
{:ex_aws, "~> 2.5"},
{:ex_aws_s3, "~> 2.5"},
```

### Step 2: Create blobs table

```elixir
create table(:blobs, primary_key: false) do
  add :hash, :string, primary_key: true  # "sha256:abc123..."
  add :size, :bigint, null: false
  add :content_type, :string
  add :reference_count, :integer, null: false, default: 1
  timestamps(type: :utc_datetime_usec)
end
```

### Step 3: Implement file storage context

`server/lib/dust/files.ex`:
- `upload(source_path_or_binary, content_type)` — hash content, upload to S3 if not already present, upsert blob record, return hash.
- `download(hash)` — stream from S3.
- `increment_ref(hash)` / `decrement_ref(hash)` — reference counting for GC.

### Step 4: Add put_file op to Writer

`put_file` is the one op that blocks on network (blob must land before reference is written).

In Writer:
```elixir
defp apply_to_entries(store_id, seq, %{op: :put_file, path: path, value: file_ref}) do
  # file_ref is already uploaded; store the reference
  Repo.insert!(
    %StoreEntry{store_id: store_id, path: path, value: wrap_value(file_ref), type: "file", seq: seq},
    on_conflict: [set: [value: wrap_value(file_ref), type: "file", seq: seq]],
    conflict_target: [:store_id, :path]
  )
end
```

### Step 5: Add file download endpoint

REST endpoint at `/api/files/:hash` for downloading blob content. Authenticated via token.

### Step 6: Write tests and commit

```bash
git commit -m "feat: add S3-backed file storage with content-addressed blobs"
```

---

## Task 12: File Type — SDK + MCP

Add file operations to the SDK and MCP endpoint.

**Files:**
- Modify: `sdk/elixir/lib/dust.ex` (put_file, file reference struct)
- Modify: `sdk/elixir/lib/dust/sync_engine.ex` (put_file handling)
- Create: `sdk/elixir/lib/dust/file_ref.ex` (file reference struct with fetch/download)
- Create: `server/lib/dust/mcp/tools/dust_put_file.ex`
- Create: `server/lib/dust/mcp/tools/dust_fetch_file.ex`
- Test: `sdk/elixir/test/dust/file_ref_test.exs`

### Step 1: Create FileRef struct

```elixir
defmodule Dust.FileRef do
  defstruct [:hash, :size, :content_type, :filename, :uploaded_at, :_server_url, :_token]

  def fetch(%__MODULE__{} = ref) do
    # HTTP GET to server's file download endpoint
  end

  def download(%__MODULE__{} = ref, path) do
    # Stream to disk
  end
end
```

### Step 2: Add SDK public API

```elixir
Dust.put_file(store, path, source_path)
# get returns a FileRef when type is "file"
```

### Step 3: Add MCP tools

`dust_put_file` and `dust_fetch_file`.

### Step 4: Write tests and commit

```bash
git commit -m "feat: add file operations to SDK and MCP endpoint"
```

---

## Task 13: Admin Panel Enhancements

Improve the AdminWeb LiveView panel for internal inspection.

**Files:**
- Modify: `server/lib/admin_web/router.ex`
- Create: `server/lib/admin_web/live/stores_live.ex`
- Create: `server/lib/admin_web/live/store_detail_live.ex`
- Create: `server/lib/admin_web/live/ops_live.ex`

### Step 1: Add Oban dashboard

```elixir
# In AdminWeb.Router:
import Oban.Web.Router

scope "/" do
  pipe_through :browser
  oban_dashboard("/oban")
end
```

### Step 2: Add store inspection pages

- **Stores** — all stores across all orgs, with key counts and sync status
- **Store Detail** — raw entry viewer, op log with filtering
- **Ops** — global op log across all stores (for debugging)

### Step 3: Commit

```bash
git commit -m "feat: enhance admin panel with store inspection and Oban dashboard"
```

---

## Task Summary

| Task | Description | Depends on |
|------|-------------|------------|
| 1 | Vite + Inertia + React setup | — |
| 2 | Shadcn/UI base components | 1 |
| 3 | WorkOS auth flow | 1 |
| 4 | Shell layout + navigation | 2, 3 |
| 5 | Dashboard pages | 4 |
| 6 | MCP endpoint (GenMCP) | — |
| 7 | Audit log | 6 (for MCP tool) |
| 8 | Counter + Set types | — |
| 9 | Decimal + DateTime types | — |
| 10 | Rollback | 7 |
| 11 | File type — server storage | — |
| 12 | File type — SDK + MCP | 11 |
| 13 | Admin panel enhancements | 5 |

**Parallelizable:** Tasks 6-9 are independent of Tasks 1-5 (dashboard). Tasks 8 and 9 are independent of each other. Tasks 11-12 can start once the server core is stable.

**Recommended execution order:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13
