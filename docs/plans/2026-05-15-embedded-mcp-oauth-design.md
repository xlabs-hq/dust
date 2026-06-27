# Embedded MCP OAuth Design

**Date:** 2026-05-15
**Status:** Proposed

## Recommendation

Make Dust the only OAuth Authorization Server for the MCP endpoint. Render the login and consent UI on Dust's own pages, call `WorkOS.UserManagement.*` server-side for credential verification, and mint Dust's own short-lived authorization codes. Stop redirecting MCP clients to WorkOS-hosted AuthKit.

This brings MCP auth into line with the human login path (which already uses embedded WorkOS UserManagement) and removes the per-domain AuthKit cost from this project.

## Why Change

Today, `mcp_auth_controller.do_authorize/7` mints a second PKCE pair against an upstream WorkOS OAuth client (`WORKOS_MCP_CLIENT_ID`) and redirects the user's browser to `${AUTHKIT_BASE_URL}/oauth2/authorize`. After the user signs in there, WorkOS calls back to `/oauth/callback`, Dust exchanges the upstream code, then mints its own session and finally redirects back to the MCP client.

Three problems:

1. **Two consent screens, two brands.** Users authorizing an MCP client see WorkOS AuthKit's login UI, not Dust's. The human login path is already embedded, so we have two inconsistent flows.
2. **AuthKit costs $100/month per domain.** Across multiple personal projects this adds up. The human path uses the cheaper UserManagement API tier; MCP is the only thing still on AuthKit.
3. **The broker pattern is unnecessary.** Dust already owns the user data and identity. Brokering through AuthKit is an OIDC-federation shape that makes sense for cross-org delegation but not for a single app issuing tokens to its own MCP clients.

The standard pattern — used by GitHub, Google, Slack, Notion, Atlassian, Linear — is for the app itself to act as the Authorization Server and treat the identity store as an internal implementation detail.

## Target Contract

### Browser Flow

```
GET /oauth/authorize?client_id=...&redirect_uri=...&state=...
                    &code_challenge=...&code_challenge_method=S256
  ├─ validate redirect_uri against the DCR-registered allowlist
  ├─ stash OAuth params in session
  └─ if signed in:  302 /oauth/authorize/continue
     else:           302 /auth/login?return_to=/oauth/authorize/continue

GET /auth/login (existing UI, untouched)
  └─ on success, honor return_to from session

GET /oauth/authorize/continue
  ├─ read OAuth params + user_id from session
  └─ render consent page (Inertia)

POST /oauth/authorize/approve
  ├─ deny:  302 client_redirect_uri?error=access_denied&state=<original>
  └─ allow:
       ├─ mint opaque code (32 random bytes, base64url), 60s TTL
       ├─ store {code → user_id, client_id, redirect_uri, challenge, method, exp}
       └─ 302 client_redirect_uri?code=<code>&state=<original>

POST /oauth/token
  ├─ verify code exists, not expired
  ├─ verify client_id and redirect_uri match the stored values
  ├─ verify SHA256(code_verifier) == stored challenge (constant-time)
  ├─ delete the code (single-use)
  └─ create Dust.MCP.Sessions row, return access_token + refresh_token
```

### Consent Page

Minimal content: client display name (from DCR metadata), "wants to access your Dust stores as <user_email>", redirect URI for transparency, Allow / Deny buttons, and a "switch account" link.

No per-scope checkboxes, no per-org disclosure, no scope model. MCP tokens grant the same access across the user's orgs that they have today.

### Discovery

`/.well-known/oauth-authorization-server` continues to advertise the same endpoints. Existing DCR clients do not need to re-register.

## Implementation Scope

### Controller — `mcp_auth_controller.ex`

1. Replace `do_authorize/7`:
   - Validate `redirect_uri` and `code_challenge_method=S256` (reject `plain`).
   - Stash OAuth params in session.
   - Redirect to `/oauth/authorize/continue` if signed in, otherwise `/auth/login?return_to=/oauth/authorize/continue`.
2. Add `authorize_continue/2`: read session, render Inertia consent page.
3. Add `authorize_approve/2`: handle Allow/Deny, mint code on Allow, redirect to client.
4. Update `token/2`: verify code via `Dust.MCP.OAuth.CodeStore`, enforce single-use, constant-time PKCE comparison.
5. Delete `oauth_callback/2`. No upstream callback to handle anymore.

### Controller — `workos_auth_controller.ex`

1. Update `sign_in/2` (and email-verification, SSO branches) to honor `return_to` from session, with an allowlist of safe paths (only `/oauth/authorize/continue` for now).

### Code storage — reuse `Dust.MCP.Sessions`

`Dust.MCP.Sessions.create_authorization_code/2` and `exchange_code/2` already exist. They persist auth codes in the `mcp_sessions` Postgres table with a 10-minute lifetime, store the PKCE challenge + method, and on successful exchange flip the row into a bearer-token session with 30-day sliding expiry.

No new storage module is needed. The new `authorize_approve` action calls `Sessions.create_authorization_code/2` directly with the user from the Dust session and the OAuth params from the verified flow token.

### Flow params — `Phoenix.Token`

The `do_authorize` step needs to thread OAuth params through `/auth/login` and `log_in_user/2` (which calls `clear_session`). Encoding them in a signed `Phoenix.Token` and passing the token in the `return_to` query string keeps the flow stateless and survives the session clear. Max age: 10 minutes.

### Router

- Remove `GET /oauth/callback`.
- Add `GET /oauth/authorize/continue` and `POST /oauth/authorize/approve`.

### Inertia page — `oauth/Authorize.tsx`

Single page that renders the consent UI described above. Submits to `POST /oauth/authorize/approve` with the user's choice.

### Config

Remove from prod env after deploy:

- `AUTHKIT_BASE_URL`
- `WORKOS_MCP_CLIENT_ID`

Delete the dedicated MCP OAuth client in the WorkOS dashboard.

Keep:

- `WORKOS_API_KEY`, `WORKOS_CLIENT_ID` — used by the human login path; embedded MCP reuses them.

## Hardening Notes

These match the bar at major OAuth-issuing apps:

- PKCE required; reject `code_challenge_method=plain`.
- Exact `redirect_uri` string match at both `/authorize` and `/token` (no prefix wildcards).
- Constant-time comparison for PKCE verification (`Plug.Crypto.secure_compare/2`).
- Single-use codes, 60s TTL.
- Rate-limit `/oauth/authorize` and `/oauth/token` per client IP.
- Refresh-token rotation on use: verify the existing `Dust.MCP.Sessions` rotation invalidates the old refresh token (RFC 6749 §10.4).

Deliberately skipped (YAGNI): scopes, revocation UI, Pushed Authorization Requests, DPoP, JWT access tokens.

## Migration Plan

Single deploy, no flag.

1. Ship the embedded flow. The replacement of `do_authorize` and the removal of `/oauth/callback` happen in the same change.
2. After deploy, remove `AUTHKIT_BASE_URL` and `WORKOS_MCP_CLIENT_ID` from prod env.
3. Delete the dedicated MCP OAuth client in the WorkOS dashboard.

**Blast radius of in-flight authorizations at deploy moment:** an MCP authorization started before the deploy that returns to `/oauth/callback` after deploy lands on a 404. The user clicks Authorize again. Acceptable.

**No revocation, no forced re-auth for existing tokens.** Already-issued MCP access tokens and refresh tokens continue to validate against `Dust.MCP.Sessions`, which doesn't care how the original code was minted.

**No DCR migration.** Registered MCP clients continue to work; embedded auth reads the same DCR table.

## Test Plan

### Controller tests

- `GET /oauth/authorize` + valid params + signed-in session → 302 to `/oauth/authorize/continue`.
- `GET /oauth/authorize` + valid params + no session → 302 to `/auth/login?return_to=/oauth/authorize/continue`; OAuth params persisted.
- `GET /oauth/authorize` + invalid `redirect_uri` → 400 `invalid_request`.
- `GET /oauth/authorize` + `code_challenge_method=plain` → 400.
- `GET /oauth/authorize/continue` renders consent with client name + user email.
- `GET /oauth/authorize/continue` with no OAuth params in session → 400.
- `POST /oauth/authorize/approve` (allow) → 302 to `client_redirect_uri?code=...&state=...`; code stored.
- `POST /oauth/authorize/approve` (deny) → 302 with `error=access_denied`.
- `POST /oauth/token` happy path → 200 with `access_token` + `refresh_token`; code deleted.
- `POST /oauth/token` with reused code → `invalid_grant`.
- `POST /oauth/token` with expired code → `invalid_grant`.
- `POST /oauth/token` with wrong PKCE verifier → `invalid_grant`.
- `POST /oauth/token` with mismatched `redirect_uri` → `invalid_grant`.
- `POST /oauth/token` with mismatched `client_id` → `invalid_grant`.

### Login controller tests

- `sign_in` with `return_to=/oauth/authorize/continue` → 302 to that path.
- `sign_in` with `return_to=https://evil.example/...` → ignored, default redirect.

### CodeStore tests

- `put` then `take` returns the attrs and removes the entry.
- `take` on missing code returns `:not_found`.
- `take` after 60s returns `:not_found`.
- Sweep removes expired entries.

### Integration test

- Full embedded flow end-to-end: `/oauth/authorize` → `/auth/login` → submit credentials → consent → Allow → `/oauth/token` → call a protected MCP endpoint with the issued token.

### Manual smoke

After deploy to staging: wire Claude Desktop to staging `/mcp`, complete OAuth via Dust's own UI, run `dust_enum` against a known store.

## Open Decisions

None at design time. Implementation may surface small choices (Inertia page layout, exact rate-limit thresholds); resolve those in the implementation plan.
