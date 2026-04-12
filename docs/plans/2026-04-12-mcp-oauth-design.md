# MCP OAuth + Feature Parity — Design

**Date:** 2026-04-12
**Status:** Approved, ready for implementation plan

## Goal

Add OAuth 2.1 authentication to the existing `/mcp` endpoint so MCP clients (Claude Desktop, ChatGPT, Cursor, etc.) can auto-discover and connect without pasting bearer tokens, and close the feature-parity gap between the CLI and the MCP tool set.

## Current state

- `/mcp` exists, runs `GenMCP.Suite` via `DustWeb.MCPTransport`.
- Authentication is bearer-only: `DustWeb.Plugs.MCPAuth` accepts `dust_tok_…` store tokens via `Dust.Stores.authenticate_token/1`. Each token is **single-store scoped**.
- Fourteen tools live under `lib/dust/mcp/tools/`: Get, Put, Merge, Delete, Enum, Increment, Add, Remove, Stores, Status, Log, PutFile, FetchFile, Rollback.

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
8. Dust exchanges the WorkOS code for user info, finds or creates a `Dust.Accounts.User`, and creates an `mcp_sessions` row with `session_id: "mcp_<uuid>"`, the **client's original PKCE challenge persisted**, the **client's `redirect_uri` and `client_id` persisted**, and `access_token_hash: nil`. The `session_id` is the OAuth authorization code we hand back.
9. Dust redirects to the client's original `redirect_uri?code=<session_id>&state=<original_state>`.
10. Client POSTs `/oauth/token` with `grant_type=authorization_code`, `code=<session_id>`, `code_verifier=<original PKCE verifier>`, `client_id`, `redirect_uri`.
11. Dust looks up the session by `session_id`, verifies it has not been exchanged (`access_token_hash IS NULL`), computes `Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)` and compares it to the stored `code_challenge`. Validates `redirect_uri` and `client_id` match the stored values. On success, generates an opaque bearer token (`:crypto.strong_rand_bytes(32) |> Base.url_encode64`), stores its SHA-256 hash on the session, sets `expires_at = now + 30d`, and returns `{access_token, token_type: "Bearer", expires_in: 2592000}`. On any mismatch returns `invalid_grant`.
12. Client uses bearer token against `/mcp`. `MCPAuth` plug SHA-256s the token, looks up the session, verifies `expires_at > now`, and — if remaining lifetime < `30d - 1h` — slides `expires_at` to `now + 30d` and bumps `last_activity_at`.

**PKCE binding rationale**: the browser session that stored `oauth_params` during `/oauth/authorize` belongs to the *user's* browser, not the MCP client. The token exchange is a back-channel POST from the MCP client process. So the PKCE challenge has to be persisted server-side, keyed by the auth code (`session_id`), not stashed in the user's cookie. Authorization codes are one-time-use, enforced by `access_token_hash IS NULL`.

### Deltas from root reference

**Delta 1 — no org binding on sessions**. Root has `mcp_sessions.organization_id`. Dust does not. Sessions belong only to a user. Tools resolve `org/store` by walking `user → memberships → stores`. This matches the CLI's behavior where store references are always `org/store`.

**Delta 2 — sliding expiry**. Root uses fixed `expires_at` from session creation. Dust extends `expires_at` on each authenticated request, throttled to once per hour (avoids a DB write per MCP request).

---

## Schemas

### Migration: `mcp_sessions`

```
id                    : uuid pk
session_id            : text unique not null         # also serves as the one-time auth code
access_token_hash     : text unique null             # null until /oauth/token consumes the auth code
user_id               : uuid fk users
client_id             : text null                    # OAuth client_id from /oauth/authorize
client_redirect_uri   : text null                    # OAuth redirect_uri from /oauth/authorize
code_challenge        : text null                    # PKCE challenge from /oauth/authorize
code_challenge_method : text null                    # always "S256"
client_name           : text null                    # populated by MCP `initialize` message later
client_version        : text null
remote_ip             : text null
user_agent            : text null
expires_at            : utc_datetime_usec not null
last_activity_at      : utc_datetime_usec not null
invalidated_at        : utc_datetime_usec null
inserted_at, updated_at
```

Indexes: `session_id`, `access_token_hash`, `user_id`.

The PKCE columns (`client_id`, `client_redirect_uri`, `code_challenge`, `code_challenge_method`) are populated at `/oauth/callback` time when the row is first created and consulted at `/oauth/token` time. We do **not** null them out after exchange — they remain on the row for audit. The `access_token_hash IS NULL` predicate is what guarantees one-time use.

### `Dust.MCP.Session` (schema)

Ecto schema mirroring the migration. No `belongs_to :organization`. No refresh token field.

### `Dust.MCP.Sessions` (context)

- `create_authorization_code(user, %{client_id, client_redirect_uri, code_challenge, code_challenge_method, remote_ip, user_agent}) → {:ok, session}` — creates the row at `/oauth/callback` time with `access_token_hash: nil` and the PKCE binding persisted.
- `exchange_code(session_id, %{code_verifier, client_id, client_redirect_uri}) → {:ok, raw_token, session} | {:error, :invalid_grant | :already_used | :pkce_mismatch | :client_mismatch}` — atomic check-and-set: validates the row hasn't been exchanged, validates PKCE and client binding, generates the opaque token, hashes it, persists, returns the raw token.
- `find_by_session_id(id) → session | nil`
- `find_by_access_token_hash(hash) → session | nil`
- `touch_and_slide(session) → {:ok, session}` (bumps `last_activity_at`; slides `expires_at` if remaining < `30d - 1h`)
- `invalidate(session) → {:ok, session}`
- `hash_token(raw) → hex string`

`exchange_code/2` is the only public function that mutates `access_token_hash`. Internally it does the row update inside a transaction with a `WHERE access_token_hash IS NULL` guard so concurrent exchange attempts cannot both succeed.

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
- `oauth_callback/2` — exchange upstream code, find/create user, call `Sessions.create_authorization_code/2` with PKCE binding pulled from `get_session(conn, :oauth_params)`, redirect to client redirect_uri with `code=session_id`.
- `oauth_token/2` — `grant_type=authorization_code` → `Sessions.exchange_code(code, %{code_verifier, client_id, redirect_uri})`. Returns `{access_token, token_type, expires_in, scope}` on success, RFC 6749 error responses on failure (`invalid_grant` for missing/used/expired/PKCE-mismatch codes, `unsupported_grant_type` for everything else).

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

### `/mcp` scope changes

The existing `/mcp` forward must change in two ways:

1. **`copy_assigns`** in the `forward "/", DustWeb.MCPTransport, …` block currently lists `[:store_token]`. Add `:mcp_principal` (and keep `:store_token` for back-compat). Without this, the GenMCP `channel.assigns` will not see the new principal.
2. **Pipeline `:accepts`** currently is `["json"]`. Verify whether GenMCP's Streamable HTTP transport requires `["json", "sse"]` for SSE upgrades. Look at `GenMCP.Transport.StreamableHTTP` source (or test against a real client) before changing — this may already work or may need the SSE accept added. Document the decision in the implementation plan.

The `:mcp` pipeline still ends in `MCPAuth`, which now sets both `:mcp_principal` and (legacy) `:store_token`.

---

## New tools

All store-targeted tools take `store: "org/store"` and route through `Dust.MCP.Authz.authorize_store/3`. The first-pass tool surface is grounded in what `Dust.Sync.{Export, Import, Diff, Clone}` actually exposes today — no new server primitives.

### `Dust.MCP.Tools.DustCreateStore`

- Inputs: `org` (slug), `name`.
- Wraps `Dust.Stores.create_store(org, %{name: name})`.
- Authz: only `:user_session` principals. `:store_token` cannot create stores. User must belong to `org` via `Accounts.user_belongs_to_org?/2`.
- Returns: `%{store: "org/name", id: "..."}`.

### `Dust.MCP.Tools.DustExport`

- Inputs: `store`.
- Wraps `Dust.Sync.Export.to_jsonl_lines/2` — returns the **NDJSON header line + entry lines** that the server already produces. Same format the CLI consumes.
- Read permission via `Authz`.
- Returns: `%{full_name: "org/store", lines: [...]}` where `lines` is the JSONL list. Cap the joined byte size at **1 MB**; if larger, error with `"Store too large for MCP transport; use the CLI: dust export org/store"`.
- We do **not** offer the SQLite export over MCP — it's binary and too large for the channel.

### `Dust.MCP.Tools.DustDiff`

- Inputs: `store`, `from_seq` (integer, required), `to_seq` (integer, optional).
- Wraps `Dust.Sync.Diff.changes(store_id, from_seq, to_seq)`.
- Read permission.
- Returns: `%{from_seq, to_seq, changes: [%{path, before, after}, ...]}`.
- On `{:error, :compacted, _}`: return a clear message asking the caller to use a more recent `from_seq`.
- **Not** version- or timestamp-based — `Sync.Diff` is seq-based and we mirror that exactly.

### `Dust.MCP.Tools.DustImport`

- Inputs: `store`, `payload` (a single string of newline-joined JSONL — same format `Dust.Sync.Export.to_jsonl_lines/2` produces).
- Wraps `Dust.Sync.Import.from_jsonl(store_id, lines, device_id)` where `device_id` is `"mcp:user:<user_id>"` or `"mcp:token:<store_token_id>"`.
- Write permission.
- Returns: `%{ok: true, entries_imported: count}` — the only summary `Sync.Import` actually returns today.
- **No `mode` parameter.** `Sync.Import.from_jsonl/3` does not support replace semantics; everything is an additive set-op write through the normal write path. If we want replace later, that's a server-side enhancement, not a tool concern.
- Cap input payload at **1 MB**.

### `Dust.MCP.Tools.DustClone`

- Inputs: `source` (`"org/store"`), `target_name`.
- Wraps `Dust.Sync.Clone.clone_store(source, source.organization, target_name)`.
- Authz: write permission on source (clone reads the entire store, so we require write to discourage drive-by exfil; subject to taste — could be relaxed to `:read`).
- Returns: `%{store: "org/target_name", id: "..."}`.
- **Same-organization only.** `Sync.Clone.clone_store/3` does not support cross-org cloning today and adding it is out of scope for this pass. The tool description should say "within the same organization" so MCP clients see the limitation in the tool catalog.

## Existing tool with bespoke semantics

### `Dust.MCP.Tools.DustStores` — not a mechanical migration

The current implementation returns the single store behind a `store_token`. Under user sessions, it must list **all stores across all orgs the user is a member of**. So this tool gets a per-principal branch:

- `:store_token` → existing behaviour (return the one store the token points at).
- `:user_session` → query stores via `Dust.Accounts.list_user_organizations(user)` then `Dust.Stores.list_stores/1` per org, return as a flat list of `%{name: "org/store", status: ...}`.

Tests in `test/dust/mcp/tools_test.exs:183` need new cases for the user-session path.

### `Dust.MCP.Tools.DustStatus` — also not mechanical

Currently returns the status of the single store behind the `store_token` and takes no `store` argument. Under user sessions, callers can have access to many stores; require an explicit `store: "org/store"` argument when the principal is `:user_session`. Branch the same way as `DustStores`.

## Migration of existing 14 tools

**Mechanical sweep** for 12 of the 14: Get, Put, Merge, Delete, Enum, Increment, Add, Remove, Log, PutFile, FetchFile, Rollback. For each:

- Replace `channel.assigns.store_token` read with `channel.assigns.mcp_principal`.
- Replace local `resolve_store/2` with call to `Dust.MCP.Authz.authorize_store/3` (use `:read` or `:write` per the tool's existing permission check).
- Delete the local permission-bit check (moved into `Authz`).

Behavior for existing `dust_tok_…` callers stays identical.

**Bespoke** (covered above): `DustStores` and `DustStatus` need new per-principal branches.

Add all 5 new tools to the `tools:` list in `router.ex`, plus the `:mcp_principal` entry in `copy_assigns`.

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

## Confirmed prerequisites (promoted to concrete tasks)

- `Dust.Accounts.user_belongs_to_org?/2` does **not** exist today and must be added. Single function over `OrganizationMembership`. Plan task: Phase 0.
- `Dust.Accounts.find_or_create_user_from_workos/1` does **not** exist; the equivalent logic is private inside `DustWeb.WorkOSAuthController`. Extract it to `Dust.Accounts` so the new MCP OAuth callback and the existing web login share one path. Plan task: Phase 0.
- `Dust.Sync.{Export, Import, Diff, Clone}` already expose plain-Elixir functions (verified) — the new MCP tools call them directly, not through the controllers. No extraction needed.

## Open items

- Decide the 1 MB cap number for export/import (1 MB feels right for Claude Desktop; could be lower for safety).
- WorkOS OAuth client provisioning is a manual operator step (`WORKOS_MCP_CLIENT_ID` env var, redirect URI = `<MCP_BASE_URL>/oauth/callback`).
- SSE accept on the `:mcp` pipeline: verify whether GenMCP's Streamable HTTP transport needs `["json", "sse"]` instead of `["json"]`. Decide during implementation by reading `GenMCP.Transport.StreamableHTTP`.
- Cross-org clone is intentionally deferred. If/when needed, it requires extending `Dust.Sync.Clone.clone_store/3` to accept a target org distinct from `source.organization`.
