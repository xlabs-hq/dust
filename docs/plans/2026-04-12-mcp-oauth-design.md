# MCP OAuth + Feature Parity — Design

**Date:** 2026-04-12
**Status:** Approved, ready for implementation plan

## Goal

Add OAuth 2.1 authentication to the existing `/mcp` endpoint so MCP clients (Claude Desktop, ChatGPT, Cursor, etc.) can auto-discover and connect without pasting bearer tokens, and close the feature-parity gap between the CLI and the MCP tool set.

## Current state

- `/mcp` exists, runs `GenMCP.Suite` via `DustWeb.MCPTransport`.
- Authentication is bearer-only: `DustWeb.Plugs.MCPAuth` accepts `dust_tok_…` store tokens via `Dust.Stores.authenticate_token/1`. Each token is **single-store scoped**.
- Thirteen tools live under `lib/dust/mcp/tools/`: Get, Put, Merge, Delete, Enum, Increment, Add, Remove, Stores, Status, Log, PutFile, FetchFile.

## Gaps being closed

**Auth**: MCP clients require OAuth + dynamic discovery. Bearer tokens don't work for zero-config install.

**Tool parity with CLI**: five CLI commands have no MCP equivalent — `create_store` (init), `export`, `diff`, `import`, `clone`.

## Non-goals

- Device flow (RFC 8628).
- Refresh tokens — sliding expiry rolls the 30d window forward on use.
- Webhook or token-management MCP tools — agents shouldn't wire outbound HTTP or mint credentials.
- Encrypted refresh token storage.
- Auto-join by email domain.

## Reference

`/Users/james/Desktop/elixir/root` — existing battle-tested Elixir MCP + WorkOS server. We mirror its shape with two deliberate deltas (below).

---

## Architecture

**Topology**: Dust acts as both the resource server and the authorization server. WorkOS AuthKit is the upstream IdP only. Clients interact only with Dust.

### Flow

1. Client hits `/mcp` with no token → 401 + `WWW-Authenticate` header pointing at `/.well-known/oauth-protected-resource`.
2. Client fetches protected-resource metadata → learns authorization server is Dust itself.
3. Client fetches `/.well-known/oauth-authorization-server` → learns `/register`, `/oauth/authorize`, `/oauth/token`.
4. Client POSTs `/register` → gets back the preconfigured WorkOS MCP `client_id` (no per-client storage).
5. Client opens `/oauth/authorize?...&code_challenge=...` in a browser.
6. Dust stores the client's PKCE challenge + redirect_uri in the Phoenix session, mints its own upstream PKCE, and redirects to `authkit_base_url/oauth2/authorize` using the MCP WorkOS client.
7. User authenticates with WorkOS, WorkOS redirects to `/oauth/callback?code=…`.
8. Dust exchanges the WorkOS code for user info via the existing WorkOS client library, finds or creates a `Dust.Accounts.User`, and creates an `mcp_sessions` row with `session_id: "mcp_<uuidv7>"` and no `access_token_hash` yet.
9. Dust redirects to the client's original `redirect_uri?code=<session_id>&state=<original_state>`.
10. Client POSTs `/oauth/token` with `grant_type=authorization_code`, `code=<session_id>`, `code_verifier=<original PKCE verifier>`.
11. Dust validates the client PKCE, generates an opaque bearer token (`:crypto.strong_rand_bytes(32) |> Base.url_encode64`), stores its SHA-256 hash on the session, sets `expires_at = now + 30d`, returns `{access_token, token_type: "Bearer", expires_in: 2592000}`.
12. Client uses bearer token against `/mcp`. `MCPAuth` plug SHA-256s the token, looks up the session, verifies `expires_at > now`, and — if remaining lifetime < `29d` — slides `expires_at` to `now + 30d` and bumps `last_activity_at`.

### Deltas from root reference

**Delta 1 — no org binding on sessions**. Root has `mcp_sessions.organization_id`. Dust does not. Sessions belong only to a user. Tools resolve `org/store` by walking `user → memberships → stores`. This matches the CLI's behavior where store references are always `org/store`.

**Delta 2 — sliding expiry**. Root uses fixed `expires_at` from session creation. Dust extends `expires_at` on each authenticated request, throttled to once per hour (avoids a DB write per MCP request).

---

## Schemas

### Migration: `mcp_sessions`

```
id              : uuid pk
session_id      : text unique not null
access_token_hash : text unique null
user_id         : uuid fk users
client_name     : text null
client_version  : text null
remote_ip       : text null
user_agent      : text null
expires_at      : utc_datetime_usec not null
last_activity_at : utc_datetime_usec not null
invalidated_at  : utc_datetime_usec null
inserted_at, updated_at
```

Indexes: `session_id`, `access_token_hash`, `user_id`.

### `Dust.MCP.Session` (schema)

Ecto schema mirroring the migration. No `belongs_to :organization`. No refresh token field.

### `Dust.MCP.Sessions` (context)

- `create_for_user(user, opts) → {:ok, session}`
- `find_by_session_id(id) → session | nil`
- `find_by_access_token_hash(hash) → session | nil`
- `set_access_token(session) → {:ok, raw_token, session}` (generates, hashes, persists, sets expires_at)
- `touch_and_slide(session) → {:ok, session}` (bumps `last_activity_at`; slides `expires_at` if < 29d remaining)
- `invalidate(session) → {:ok, session}`
- `hash_token(raw) → hex string`

### `Dust.MCP.Principal` (unified auth principal)

Tagged struct set at `conn.assigns.mcp_principal`:

```elixir
%Dust.MCP.Principal{
  kind: :store_token | :user_session,
  user: %User{} | nil,
  store_token: %StoreToken{} | nil,
  session: %Dust.MCP.Session{} | nil
}
```

### `Dust.MCP.Authz`

Single helper every tool calls:

```elixir
Authz.authorize_store(principal, "org/store", :read | :write) ::
  {:ok, %Store{}} | {:error, String.t()}
```

- `:store_token` principal → existing check (`store.id == store_token.store_id` + permission bit).
- `:user_session` principal → `Dust.Accounts.user_belongs_to_org?(user, store.organization_id)` (confirm function name during implementation).

---

## Plug changes

### `DustWeb.Plugs.MCPAuth`

- Extract bearer token.
- If `dust_tok_…` prefix → existing path, wrap result in `%Principal{kind: :store_token}`.
- Else → `Dust.MCP.Sessions.find_by_access_token_hash/1`, check `expires_at > now`, call `touch_and_slide/1`, wrap in `%Principal{kind: :user_session}`.
- On failure: 401 JSON + `WWW-Authenticate: Bearer error="unauthorized", error_description="…", resource_metadata="<base_url>/.well-known/oauth-protected-resource"`.
- Assigns: `:mcp_principal` (new), `:store_token` (legacy, for any not-yet-migrated code), `:current_user`.

---

## OAuth controller

### `DustWeb.MCPAuthController`

- `oauth_protected_resource/2` — static JSON: `{resource, authorization_servers: [self], bearer_methods_supported: ["header"]}`.
- `oauth_authorization_server/2` — static JSON: issuer, authorization_endpoint, token_endpoint, registration_endpoint, response_types, grant_types (`authorization_code` only), PKCE (`S256`), auth methods (`none`).
- `register/2` — always returns the preconfigured WorkOS MCP `client_id`. No storage.
- `oauth_authorize/2` — validate params, store client PKCE + redirect_uri in session, mint our own upstream PKCE, redirect to `authkit/oauth2/authorize`.
- `oauth_callback/2` — exchange upstream code, find/create user, create session record, redirect to client redirect_uri with `code=session_id`.
- `oauth_token/2` — `grant_type=authorization_code` → `Sessions.set_access_token/1`, return `{access_token, token_type, expires_in, scope}`. All other grant types return `unsupported_grant_type`.

### User lookup/creation

Reuse the logic path used by `DustWeb.WorkOSAuthController` during normal login — extract a shared helper (`Dust.Accounts.find_or_create_from_workos/1`) if not already one.

---

## Router changes

```elixir
pipeline :mcp_oauth do
  plug :accepts, ["json", "html"]
  plug :fetch_session
  plug Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason
end

scope "/", DustWeb do
  pipe_through :mcp_oauth

  get  "/.well-known/oauth-protected-resource", MCPAuthController, :oauth_protected_resource
  get  "/.well-known/oauth-authorization-server", MCPAuthController, :oauth_authorization_server
  post "/register", MCPAuthController, :register
  get  "/oauth/authorize", MCPAuthController, :oauth_authorize
  get  "/oauth/callback", MCPAuthController, :oauth_callback
  post "/oauth/token", MCPAuthController, :oauth_token
end
```

Existing `/mcp` scope unchanged apart from the plug update.

---

## New tools

All parameterised on `store: "org/store"`, all go through `Dust.MCP.Authz.authorize_store/3`.

### `Dust.MCP.Tools.DustCreateStore`

- Inputs: `org` (string), `name` (string), `description` (optional).
- Wraps `Dust.Stores.create_store/2`.
- Authz: user must belong to org (no store exists yet — separate check: `Accounts.user_belongs_to_org?/2`).
- Returns: `%{store: "org/name", id: "..."}`.

### `Dust.MCP.Tools.DustExport`

- Inputs: `store`.
- Wraps whatever `DustWeb.Api.ExportController` calls (verify during implementation).
- Read permission.
- Returns: export payload as JSON. Cap at 1 MB — if larger, return `{:error, "Store too large for MCP transport; use the CLI: dust export #{store}"}`.

### `Dust.MCP.Tools.DustDiff`

- Inputs: `store`, `from_version` (or `since_timestamp`), `to_version`.
- Wraps `DustWeb.Api.DiffController`'s code path.
- Read permission.
- Returns: structured diff.

### `Dust.MCP.Tools.DustImport`

- Inputs: `store`, `payload` (export format), `mode` (`"merge"` | `"replace"`, default `"merge"`).
- Wraps `DustWeb.Api.ImportController`'s code path.
- Write permission.
- Returns: summary (keys added/changed/removed).
- Same 1 MB cap on input.

### `Dust.MCP.Tools.DustClone`

- Inputs: `source_store` (`"org/store"`), `target_org`, `target_name`.
- Wraps `DustWeb.Api.CloneController`'s code path.
- Authz: read on source, write/create on target.
- Returns: `%{store: "target_org/target_name"}`.

## Migration of existing 13 tools

Mechanical sweep. For each tool:

- Replace `channel.assigns.store_token` read with `channel.assigns.mcp_principal`.
- Replace local `resolve_store/2` with call to `Dust.MCP.Authz.authorize_store/3`.
- Delete the permission-bit check (moved into `Authz`).

Behavior for existing `dust_tok_…` clients: identical. Single commit.

Add all 5 new tools to the `tools:` list in `router.ex`.

---

## Testing

- `test/dust_web/plugs/mcp_auth_test.exs` — both token kinds, 401 + WWW-Authenticate, sliding expiry triggers (mock clock), expired token rejected.
- `test/dust_web/controllers/mcp_auth_controller_test.exs` — discovery JSON shapes, `/register` returns expected client_id, `/oauth/authorize` redirects with PKCE rewritten, `/oauth/callback` with stubbed WorkOS client creates session and redirects to client, `/oauth/token` exchanges session_id for bearer, used bearer authenticates `/mcp`.
- `test/dust/mcp/authz_test.exs` — user_session crosses orgs, store_token behavior unchanged, permission enforcement.
- `test/dust/mcp/tools_test.exs` — add cases for the 5 new tools (happy path + unauthorized).

---

## Config

### `config/runtime.exs`

```elixir
config :dust, :mcp_base_url, System.get_env("MCP_BASE_URL") || DustWeb.Endpoint.url()
config :workos, :mcp_client_id, System.fetch_env!("WORKOS_MCP_CLIENT_ID")
config :dust, :authkit_base_url, System.fetch_env!("AUTHKIT_BASE_URL")
```

### WorkOS dashboard

Create a second OAuth client dedicated to MCP (separate from the web-login client). Redirect URI: `<mcp_base_url>/oauth/callback`. Capture `client_id` → `WORKOS_MCP_CLIENT_ID` env var.

---

## Docs

Add a short section to `AGENTS.md`:

- The `/mcp` endpoint URL and OAuth discovery endpoints.
- How to wire Claude Desktop / Cursor / ChatGPT via "Add MCP Server by URL".
- Note that existing `dust_tok_` bearer tokens still work for programmatic clients.

---

## Open items for implementation

- Confirm exact name of `Dust.Accounts.user_belongs_to_org?/2` (or equivalent). If missing, add it.
- Confirm export/import/diff/clone controller internals expose a plain-Elixir function that can be called outside the Plug pipeline. If not, extract shared `Dust.Stores` functions.
- Decide the 1 MB cap number (1 MB feels right for Claude Desktop; could be lower for safety).
