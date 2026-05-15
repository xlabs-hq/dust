# Embedded MCP OAuth Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the AuthKit redirect on `/oauth/authorize` with an embedded login + consent flow that reuses Dust's own login UI and ends with a `Dust.MCP.Sessions.create_authorization_code/2` call. Delete the upstream WorkOS broker entirely.

**Architecture:** When an MCP client hits `/oauth/authorize`, encode the OAuth flow params as a signed `Phoenix.Token` and either redirect to `/oauth/authorize/continue?flow=<token>` (if signed in) or to `/auth/login?return_to=/oauth/authorize/continue?flow=<token>` (if not). The existing `log_in_user/2` already honors `:user_return_to`. On the continue route, render an Inertia consent page; on approve, mint the code via the existing `Sessions.create_authorization_code/2`.

**Tech Stack:** Phoenix controllers, Inertia.js + React, `Phoenix.Token` for flow params, existing `Dust.MCP.Sessions` for code/token issuance.

**Design doc:** `docs/plans/2026-05-15-embedded-mcp-oauth-design.md`

---

## Pre-flight

Before starting, confirm baseline tests pass:

```
cd /Users/james/Desktop/elixir/dust/server
mix test test/dust_web/controllers/mcp_auth_controller_test.exs
```

Expected: all current tests pass. If anything is red, stop and investigate before touching this code.

---

### Task 1: Add Phoenix.Token flow encoding helpers

**Files:**
- Modify: `server/lib/dust_web/controllers/mcp_auth_controller.ex`
- Test: `server/test/dust_web/controllers/mcp_auth_controller_test.exs`

Introduces two private helpers — `encode_flow_token/2` and `verify_flow_token/2` — used by the new actions. Phoenix.Token signs/verifies opaque tokens that survive `clear_session`.

**Step 1: Write the failing test**

Add to `test/dust_web/controllers/mcp_auth_controller_test.exs`:

```elixir
describe "flow token roundtrip" do
  test "encode then verify returns the original oauth_params", %{conn: conn} do
    params = %{
      client_id: "client_123",
      redirect_uri: "https://app.example/cb",
      state: "abc",
      code_challenge: "challenge",
      code_challenge_method: "S256",
      scope: ""
    }

    token = DustWeb.MCPAuthController.__test_encode_flow_token__(conn, params)
    assert {:ok, ^params} = DustWeb.MCPAuthController.__test_verify_flow_token__(conn, token)
  end

  test "verify rejects tampered token", %{conn: conn} do
    assert {:error, _} =
             DustWeb.MCPAuthController.__test_verify_flow_token__(conn, "not-a-real-token")
  end
end
```

**Step 2: Run test to verify it fails**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs --only describe:"flow token roundtrip"
```

Expected: FAIL — undefined function `__test_encode_flow_token__/2`.

**Step 3: Implement helpers**

Add to `lib/dust_web/controllers/mcp_auth_controller.ex` (near the bottom, before the closing `end`):

```elixir
@flow_token_salt "mcp_oauth_flow_v1"
# 10 minutes is enough for a login + SSO bounce.
@flow_token_max_age 600

defp encode_flow_token(conn, oauth_params) do
  Phoenix.Token.sign(conn, @flow_token_salt, oauth_params)
end

defp verify_flow_token(conn, token) do
  Phoenix.Token.verify(conn, @flow_token_salt, token, max_age: @flow_token_max_age)
end

# Test-only entry points. Public so the unit test can call them without
# routing the full HTTP flow.
@doc false
def __test_encode_flow_token__(conn, params), do: encode_flow_token(conn, params)
@doc false
def __test_verify_flow_token__(conn, token), do: verify_flow_token(conn, token)
```

**Step 4: Run tests to verify they pass**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs --only describe:"flow token roundtrip"
```

Expected: PASS.

**Step 5: Commit**

```bash
git add lib/dust_web/controllers/mcp_auth_controller.ex test/dust_web/controllers/mcp_auth_controller_test.exs
git commit -m "feat(mcp-oauth): add Phoenix.Token helpers for flow params"
```

---

### Task 2: Rewrite `do_authorize/7` to redirect to embedded login/consent

**Files:**
- Modify: `server/lib/dust_web/controllers/mcp_auth_controller.ex:97-135`
- Test: `server/test/dust_web/controllers/mcp_auth_controller_test.exs`

Replace the AuthKit redirect. If the user has a Dust session (`:user_token` in session), go straight to `/oauth/authorize/continue?flow=<token>`. Otherwise, set `:user_return_to` to the continue URL and redirect to `/auth/login`.

**Step 1: Write the failing tests**

```elixir
describe "GET /oauth/authorize (embedded flow)" do
  setup do
    %{
      params: %{
        "response_type" => "code",
        "client_id" => "client_123",
        "redirect_uri" => "https://app.example/cb",
        "state" => "client-state",
        "code_challenge" => "abc",
        "code_challenge_method" => "S256"
      }
    }
  end

  test "redirects unauthenticated user to /auth/login with return_to", %{conn: conn, params: params} do
    # Stub redirect_uri allowlist for the test (see Task 9 — test helper)
    conn = put_allowlisted_redirect(conn, params["redirect_uri"])

    conn = get(conn, ~p"/oauth/authorize?#{params}")

    assert redirected_to(conn) =~ "/auth/login"
    assert get_session(conn, :user_return_to) =~ "/oauth/authorize/continue?flow="
  end

  test "redirects signed-in user straight to /oauth/authorize/continue", %{conn: conn, params: params} do
    user = user_fixture()
    conn =
      conn
      |> put_allowlisted_redirect(params["redirect_uri"])
      |> log_in_user(user)
      |> get(~p"/oauth/authorize?#{params}")

    assert redirected_to(conn) =~ "/oauth/authorize/continue?flow="
    refute get_session(conn, :user_return_to)
  end

  test "rejects code_challenge_method=plain", %{conn: conn, params: params} do
    params = Map.put(params, "code_challenge_method", "plain")
    conn = get(conn, ~p"/oauth/authorize?#{params}")
    assert json_response(conn, 400)["error"] == "invalid_request"
  end
end
```

**Step 2: Run tests to verify they fail**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs --only describe:"GET /oauth/authorize (embedded flow)"
```

Expected: FAIL — redirect targets are wrong; today the code redirects to AuthKit.

**Step 3: Replace `do_authorize/7`**

Replace lines 97-135 with:

```elixir
defp do_authorize(conn, client_id, redirect_uri, state, challenge, method, params) do
  oauth_params = %{
    client_id: client_id,
    redirect_uri: redirect_uri,
    state: state,
    code_challenge: challenge,
    code_challenge_method: method,
    scope: Map.get(params, "scope", "")
  }

  flow_token = encode_flow_token(conn, oauth_params)
  continue_path = "/oauth/authorize/continue?" <> URI.encode_query(%{flow: flow_token})

  if signed_in?(conn) do
    redirect(conn, to: continue_path)
  else
    conn
    |> put_session(:user_return_to, continue_path)
    |> redirect(to: "/auth/login")
  end
end

defp signed_in?(conn) do
  not is_nil(get_session(conn, :user_token))
end
```

Also remove the now-unused `Dust.WorkOSClient` alias from the top of the file (line 8).

**Step 4: Run tests to verify they pass**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs
```

Expected: the three new tests pass. Existing `oauth_callback` tests still pass for now (we delete them in Task 4).

**Step 5: Commit**

```bash
git add lib/dust_web/controllers/mcp_auth_controller.ex test/dust_web/controllers/mcp_auth_controller_test.exs
git commit -m "feat(mcp-oauth): redirect authorize to embedded login + continue"
```

---

### Task 3: Add `authorize_continue/2` action + router entry

**Files:**
- Modify: `server/lib/dust_web/controllers/mcp_auth_controller.ex`
- Modify: `server/lib/dust_web/router.ex:163-165`
- Test: `server/test/dust_web/controllers/mcp_auth_controller_test.exs`

Renders the consent page. Requires a signed-in user — if not, send back through `/oauth/authorize` (rather than show a generic login link, so the flow token is regenerated cleanly).

**Step 1: Write the failing tests**

```elixir
describe "GET /oauth/authorize/continue" do
  setup do
    user = user_fixture()
    oauth_params = %{
      client_id: "client_123",
      redirect_uri: "https://app.example/cb",
      state: "client-state",
      code_challenge: "abc",
      code_challenge_method: "S256",
      scope: ""
    }
    %{user: user, oauth_params: oauth_params}
  end

  test "renders consent inertia page when signed in with valid flow token", ctx do
    %{conn: conn, user: user, oauth_params: oauth_params} = ctx
    token = DustWeb.MCPAuthController.__test_encode_flow_token__(conn, oauth_params)

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/oauth/authorize/continue?flow=#{token}")

    assert html_response(conn, 200) =~ "OAuth/Authorize"
    # Inertia page payload visible in <div id="app" data-page=...
    assert response(conn, 200) =~ oauth_params.client_id
    assert response(conn, 200) =~ user.email
  end

  test "redirects to /auth/login when not signed in", ctx do
    %{conn: conn, oauth_params: oauth_params} = ctx
    token = DustWeb.MCPAuthController.__test_encode_flow_token__(conn, oauth_params)

    conn = get(conn, ~p"/oauth/authorize/continue?flow=#{token}")
    assert redirected_to(conn) =~ "/auth/login"
  end

  test "rejects invalid flow token with 400", %{conn: conn} do
    user = user_fixture()
    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/oauth/authorize/continue?flow=bogus")

    assert json_response(conn, 400)["error"] == "invalid_request"
  end
end
```

**Step 2: Run tests to verify they fail**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs --only describe:"GET /oauth/authorize/continue"
```

Expected: FAIL — route doesn't exist.

**Step 3: Add the action**

Add to `lib/dust_web/controllers/mcp_auth_controller.ex` (alongside the other actions):

```elixir
def authorize_continue(conn, %{"flow" => flow_token}) do
  cond do
    not signed_in?(conn) ->
      conn
      |> put_session(:user_return_to, current_path(conn))
      |> redirect(to: "/auth/login")

    true ->
      case verify_flow_token(conn, flow_token) do
        {:ok, oauth_params} ->
          user = current_user(conn)

          render_inertia(conn, "OAuth/Authorize", %{
            client_id: oauth_params.client_id,
            client_name: client_display_name(oauth_params.client_id),
            redirect_uri: oauth_params.redirect_uri,
            user_email: user.email,
            flow: flow_token
          })

        {:error, _} ->
          json_error(conn, :bad_request, "invalid_request", "Flow token is invalid or expired")
      end
  end
end

def authorize_continue(conn, _params) do
  json_error(conn, :bad_request, "invalid_request", "Missing flow token")
end

defp current_user(conn) do
  token = get_session(conn, :user_token)
  Dust.Accounts.get_user_by_session_token(token)
end

# DCR clients don't yet store a display name in the DB; fall back to client_id.
# When DCR persistence lands, look up the registered client name here.
defp client_display_name(client_id), do: client_id
```

**Step 4: Add the route**

In `lib/dust_web/router.ex`, add after line 163 (`get "/oauth/authorize", ...`):

```elixir
    get "/oauth/authorize/continue", MCPAuthController, :authorize_continue
```

**Step 5: Run tests**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs --only describe:"GET /oauth/authorize/continue"
```

Expected: PASS.

**Step 6: Commit**

```bash
git add lib/dust_web/controllers/mcp_auth_controller.ex lib/dust_web/router.ex test/dust_web/controllers/mcp_auth_controller_test.exs
git commit -m "feat(mcp-oauth): add authorize_continue action for consent render"
```

---

### Task 4: Add `authorize_approve/2` action + delete `oauth_callback`

**Files:**
- Modify: `server/lib/dust_web/controllers/mcp_auth_controller.ex` (add approve, delete callback)
- Modify: `server/lib/dust_web/router.ex` (add POST approve, delete GET callback)
- Test: `server/test/dust_web/controllers/mcp_auth_controller_test.exs`

On Allow: mint code via `Sessions.create_authorization_code/2`, redirect to client. On Deny: redirect with `error=access_denied`.

**Step 1: Write the failing tests**

```elixir
describe "POST /oauth/authorize/approve" do
  setup do
    user = user_fixture()
    oauth_params = %{
      client_id: "client_123",
      redirect_uri: "https://app.example/cb",
      state: "client-state",
      code_challenge: "abc",
      code_challenge_method: "S256",
      scope: ""
    }
    %{user: user, oauth_params: oauth_params}
  end

  test "allow mints code and redirects to client_redirect_uri", ctx do
    %{conn: conn, user: user, oauth_params: oauth_params} = ctx
    token = DustWeb.MCPAuthController.__test_encode_flow_token__(conn, oauth_params)

    conn =
      conn
      |> log_in_user(user)
      |> post(~p"/oauth/authorize/approve", %{"flow" => token, "action" => "allow"})

    location = redirected_to(conn)
    assert location =~ "https://app.example/cb?"
    assert location =~ "code="
    assert location =~ "state=client-state"

    # The minted code should resolve via Sessions.find_by_session_id/1
    code = URI.parse(location).query |> URI.decode_query() |> Map.fetch!("code")
    assert %Dust.MCP.Session{user_id: user_id} = Dust.MCP.Sessions.find_by_session_id(code)
    assert user_id == user.id
  end

  test "deny redirects with error=access_denied", ctx do
    %{conn: conn, user: user, oauth_params: oauth_params} = ctx
    token = DustWeb.MCPAuthController.__test_encode_flow_token__(conn, oauth_params)

    conn =
      conn
      |> log_in_user(user)
      |> post(~p"/oauth/authorize/approve", %{"flow" => token, "action" => "deny"})

    location = redirected_to(conn)
    assert location =~ "error=access_denied"
    assert location =~ "state=client-state"
  end

  test "requires signed-in user", ctx do
    %{conn: conn, oauth_params: oauth_params} = ctx
    token = DustWeb.MCPAuthController.__test_encode_flow_token__(conn, oauth_params)

    conn = post(conn, ~p"/oauth/authorize/approve", %{"flow" => token, "action" => "allow"})
    assert redirected_to(conn) =~ "/auth/login"
  end
end
```

**Step 2: Run tests to verify they fail**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs --only describe:"POST /oauth/authorize/approve"
```

Expected: FAIL — route doesn't exist.

**Step 3: Implement `authorize_approve/2`**

Add to `lib/dust_web/controllers/mcp_auth_controller.ex`:

```elixir
def authorize_approve(conn, %{"flow" => flow_token, "action" => action})
    when action in ["allow", "deny"] do
  cond do
    not signed_in?(conn) ->
      redirect(conn, to: "/auth/login")

    true ->
      case verify_flow_token(conn, flow_token) do
        {:ok, oauth_params} ->
          do_approve(conn, oauth_params, action)

        {:error, _} ->
          json_error(conn, :bad_request, "invalid_request", "Flow token is invalid or expired")
      end
  end
end

def authorize_approve(conn, _params) do
  json_error(conn, :bad_request, "invalid_request", "Missing flow or action")
end

defp do_approve(conn, oauth_params, "deny") do
  url = error_redirect(oauth_params.redirect_uri, "access_denied", oauth_params.state)
  redirect(conn, external: url)
end

defp do_approve(conn, oauth_params, "allow") do
  user = current_user(conn)

  case Sessions.create_authorization_code(user, %{
         client_id: oauth_params.client_id,
         client_redirect_uri: oauth_params.redirect_uri,
         code_challenge: oauth_params.code_challenge,
         code_challenge_method: oauth_params.code_challenge_method,
         remote_ip: peer_ip(conn),
         user_agent: user_agent(conn)
       }) do
    {:ok, session} ->
      url = build_callback_url(oauth_params.redirect_uri, session.session_id, oauth_params.state)
      redirect(conn, external: url)

    {:error, reason} ->
      Logger.error("create_authorization_code failed: #{inspect(reason)}")
      url = error_redirect(oauth_params.redirect_uri, "server_error", oauth_params.state)
      redirect(conn, external: url)
  end
end

defp error_redirect(redirect_uri, error, state) do
  uri = URI.parse(redirect_uri)
  existing = if uri.query, do: URI.decode_query(uri.query), else: %{}
  query = existing |> Map.put("error", error) |> Map.put("state", state) |> URI.encode_query()
  URI.to_string(%{uri | query: query})
end
```

**Step 4: Delete `oauth_callback/2` and `do_callback/6`**

Remove lines 137-185 (the entire `oauth_callback` and `do_callback` functions). Also remove the `alias Dust.Accounts` import if `current_user/1` doesn't need it — actually it does, via `Dust.Accounts.get_user_by_session_token`. Keep it.

**Step 5: Update router**

In `lib/dust_web/router.ex`:
- Delete line 164: `get "/oauth/callback", MCPAuthController, :oauth_callback`
- Add: `post "/oauth/authorize/approve", MCPAuthController, :authorize_approve`

**Step 6: Run tests**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs
```

Expected: new approve tests pass; previously-existing `oauth_callback` tests are gone with the route.

**Step 7: Commit**

```bash
git add lib/dust_web/controllers/mcp_auth_controller.ex lib/dust_web/router.ex test/dust_web/controllers/mcp_auth_controller_test.exs
git commit -m "feat(mcp-oauth): add authorize_approve, delete oauth_callback"
```

---

### Task 5: Add Inertia consent page `OAuth/Authorize.tsx`

**Files:**
- Create: `server/assets/js/pages/OAuth/Authorize.tsx`

A simple React component rendering the consent UI. Posts to `/oauth/authorize/approve` with action=allow or action=deny.

**Step 1: Look at an existing Inertia auth page for style reference**

Read `server/assets/js/pages/Auth/Login.tsx` to match imports, layout, and form-post pattern. Use Inertia's `router.post(...)` for the form submission so CSRF is handled automatically.

**Step 2: Write the page**

```tsx
import { router } from "@inertiajs/react";

interface AuthorizeProps {
  client_id: string;
  client_name: string;
  redirect_uri: string;
  user_email: string;
  flow: string;
}

export default function Authorize({
  client_name,
  redirect_uri,
  user_email,
  flow,
}: AuthorizeProps) {
  const submit = (action: "allow" | "deny") => {
    router.post("/oauth/authorize/approve", { flow, action });
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-neutral-50 p-6">
      <div className="max-w-md w-full bg-white rounded-2xl shadow-sm border border-neutral-200 p-8">
        <h1 className="text-xl font-semibold mb-2">Authorize MCP client</h1>

        <div className="mt-6 space-y-4">
          <div>
            <div className="text-lg font-medium">{client_name}</div>
            <div className="text-neutral-600 text-sm mt-1">
              wants to access your Dust stores.
            </div>
          </div>

          <div className="border-t border-neutral-200 pt-4 text-sm text-neutral-600">
            Signed in as <span className="text-neutral-900">{user_email}</span>{" "}
            <a href="/auth/login" className="text-blue-600 hover:underline">
              (switch account)
            </a>
          </div>

          <div className="text-xs text-neutral-500 break-all">
            Redirect URI: <span className="font-mono">{redirect_uri}</span>
          </div>
        </div>

        <div className="mt-8 flex gap-3 justify-end">
          <button
            type="button"
            onClick={() => submit("deny")}
            className="px-4 py-2 rounded-lg border border-neutral-300 hover:bg-neutral-50"
          >
            Deny
          </button>
          <button
            type="button"
            onClick={() => submit("allow")}
            className="px-4 py-2 rounded-lg bg-neutral-900 text-white hover:bg-neutral-800"
          >
            Allow
          </button>
        </div>
      </div>
    </div>
  );
}
```

**Step 3: Verify the page builds**

```
cd /Users/james/Desktop/elixir/dust/server
mix assets.build
```

Expected: builds without errors.

**Step 4: Commit**

```bash
git add assets/js/pages/OAuth/Authorize.tsx
git commit -m "feat(mcp-oauth): add Inertia consent page"
```

---

### Task 6: Update `mcp_oauth` pipeline to handle HTML + sessions

**Files:**
- Modify: `server/lib/dust_web/router.ex:38-41`

The current `:mcp_oauth` pipeline only does `:accepts ["json", "html"]` and `:fetch_session`. With the new flow we also need CSRF protection for the POST and Inertia rendering. Easiest: route the embedded flow through the existing `:browser` + `:inertia` pipelines instead.

**Step 1: Split the routes**

In `lib/dust_web/router.ex`:

- Keep under `:mcp_oauth` (JSON endpoints + GET authorize which doesn't render HTML):
  - `/.well-known/oauth-protected-resource`
  - `/.well-known/oauth-authorization-server`
  - `POST /register`
  - `GET /oauth/authorize`
  - `POST /oauth/token`

- Move to a new scope under `[:browser, :inertia]`:
  - `GET /oauth/authorize/continue`
  - `POST /oauth/authorize/approve`

Concretely, add a new scope below the existing mcp_oauth scope:

```elixir
scope "/", DustWeb do
  pipe_through [:browser, :inertia]
  get "/oauth/authorize/continue", MCPAuthController, :authorize_continue
  post "/oauth/authorize/approve", MCPAuthController, :authorize_approve
end
```

And update Task 3 and Task 4's router edits to drop the entries from `:mcp_oauth`.

- Also delete the `put_format("html")` and `Phoenix.Controller.fetch_flash()` workarounds from `authorize_continue/2` — the pipeline now provides both.

**Step 2: Run all controller tests**

```
mix test test/dust_web/controllers/mcp_auth_controller_test.exs
```

Expected: PASS (CSRF token handled by ConnTest helpers).

**Step 3: Commit**

```bash
git add lib/dust_web/router.ex
git commit -m "chore(mcp-oauth): route continue/approve through browser+inertia pipeline"
```

---

### Task 7: Integration test — full embedded flow end-to-end

**Files:**
- Create: `server/test/dust_web/integration/mcp_oauth_embedded_test.exs`

**Step 1: Write the test**

```elixir
defmodule DustWeb.Integration.MCPOAuthEmbeddedTest do
  use DustWeb.ConnCase, async: false

  import Dust.AccountsFixtures

  alias Dust.MCP.Sessions

  test "full embedded MCP OAuth flow", %{conn: conn} do
    user = user_fixture()
    redirect_uri = "https://app.example/cb"
    client_id = "client_123"

    code_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    code_challenge =
      :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

    # 1. /oauth/authorize — unauthenticated → redirects to /auth/login
    params = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "state" => "client-state",
      "code_challenge" => code_challenge,
      "code_challenge_method" => "S256"
    }

    conn = put_allowlisted_redirect(conn, redirect_uri)
    conn = get(conn, ~p"/oauth/authorize?#{params}")
    assert redirected_to(conn) =~ "/auth/login"
    return_to = get_session(conn, :user_return_to)
    assert return_to =~ "/oauth/authorize/continue?flow="

    # 2. Sign in
    conn = log_in_user(conn, user)

    # 3. Follow return_to → consent page
    conn = get(conn, return_to)
    assert html_response(conn, 200) =~ "OAuth/Authorize"

    # Extract flow token from the URL we know
    flow_token = URI.parse(return_to).query |> URI.decode_query() |> Map.fetch!("flow")

    # 4. Approve
    conn = post(conn, ~p"/oauth/authorize/approve", %{"flow" => flow_token, "action" => "allow"})
    location = redirected_to(conn)
    assert location =~ "https://app.example/cb?"
    code = URI.parse(location).query |> URI.decode_query() |> Map.fetch!("code")

    # 5. Exchange code at /oauth/token
    conn =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => code_verifier,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri
      })

    body = json_response(conn, 200)
    assert body["access_token"]
    assert body["token_type"] == "Bearer"

    # 6. Reusing the code fails
    conn =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => code_verifier,
        "client_id" => client_id,
        "redirect_uri" => redirect_uri
      })

    assert json_response(conn, 400)["error"] == "invalid_grant"
  end
end
```

**Step 2: Run**

```
mix test test/dust_web/integration/mcp_oauth_embedded_test.exs
```

Expected: PASS.

**Step 3: Commit**

```bash
git add test/dust_web/integration/mcp_oauth_embedded_test.exs
git commit -m "test(mcp-oauth): end-to-end embedded flow integration test"
```

---

### Task 8: Remove unused AuthKit config

**Files:**
- Modify: `server/config/runtime.exs`
- Modify: `server/config/config.exs`
- Modify: `server/config/test.exs`
- Modify: `server/lib/dust/workos_client.ex` and `default.ex` (if `exchange_and_get_user` is only used by the deleted `oauth_callback`)

**Step 1: Find AuthKit references**

```
grep -rn "authkit_base_url\|AUTHKIT_BASE_URL\|mcp_client_id\|WORKOS_MCP_CLIENT_ID\|exchange_and_get_user" /Users/james/Desktop/elixir/dust/server/lib /Users/james/Desktop/elixir/dust/server/config
```

**Step 2: Delete the references**

- Remove `AUTHKIT_BASE_URL` env var read from `config/runtime.exs`.
- Remove `WORKOS_MCP_CLIENT_ID` env var read from `config/runtime.exs`.
- Remove `Application.fetch_env!(:workos, :mcp_client_id)` from `register/2` in `mcp_auth_controller.ex:39` — replace with the registered client_id from DCR (for now, just pass through `params["client_id"]` if present, else generate a UUID).
- Delete `WorkOSClient.exchange_and_get_user/1` if grep confirms it has no remaining callers.

**Step 3: Run full test suite**

```
mix test
```

Expected: PASS.

**Step 4: Commit**

```bash
git add config/ lib/dust/workos_client.ex lib/dust/workos_client/default.ex lib/dust_web/controllers/mcp_auth_controller.ex
git commit -m "chore(mcp-oauth): remove unused AuthKit config and broker code"
```

---

### Task 9: Add test helper `put_allowlisted_redirect/2`

**Files:**
- Modify: `server/test/support/conn_case.ex`

The tests above assume a helper to allowlist a redirect URI for a test. Inspect `lib/dust_web/oauth/redirect_uri_validator.ex` to decide the minimal mock: probably stash an allowlist in `Application.put_env/3` for the test process or set up an ETS table.

This task can run earlier if it's blocking. If `RedirectUriValidator` already trusts a public allowlist that includes `https://app.example/cb`, no helper is needed.

**Step 1: Read the validator**

```
cat /Users/james/Desktop/elixir/dust/server/lib/dust_web/oauth/redirect_uri_validator.ex
```

**Step 2: Add the helper if needed**

```elixir
# In test/support/conn_case.ex
def put_allowlisted_redirect(conn, uri) do
  Application.put_env(:dust, :mcp_redirect_uri_allowlist, [uri])
  on_exit(fn -> Application.delete_env(:dust, :mcp_redirect_uri_allowlist) end)
  conn
end
```

Adjust to whatever shape the validator actually reads.

**Step 3: Commit**

```bash
git add test/support/conn_case.ex
git commit -m "test(mcp-oauth): add put_allowlisted_redirect helper"
```

---

### Task 10: `mix precommit` + manual smoke

**Step 1: Full precommit**

```
cd /Users/james/Desktop/elixir/dust/server
mix precommit
```

Expected: all pass.

**Step 2: Local manual smoke**

1. Start a dev server (you, not me — never start phoenix from this session).
2. Open `http://localhost:7755/oauth/authorize?response_type=code&client_id=test&redirect_uri=<allowlisted>&state=abc&code_challenge=...&code_challenge_method=S256` in a private browser window.
3. Confirm: lands on `/auth/login`, sign in, lands on consent page with client name + email, click Allow, redirects to `<redirect_uri>?code=...&state=abc`.

**Step 3: Staging smoke**

After deploy to staging:
- Add the dustlayer-staging MCP server to Claude Desktop with the new `/mcp` URL.
- Complete OAuth via Dust's own login UI (should never see AuthKit).
- Run `dust_enum` against a known store.

**Step 4: Delete unused env vars from prod**

After production deploy is healthy:
- Remove `AUTHKIT_BASE_URL` and `WORKOS_MCP_CLIENT_ID` from prod env.
- Delete the dedicated MCP OAuth client in the WorkOS dashboard.

---

## Verification checklist

Before declaring done, confirm:

- [ ] `mix precommit` passes.
- [ ] All new tests pass.
- [ ] Manual flow works locally: authorize → login → consent → token exchange.
- [ ] No references remain to `AUTHKIT_BASE_URL`, `mcp_client_id`, `WORKOS_MCP_CLIENT_ID`, or `exchange_and_get_user`.
- [ ] `/oauth/callback` returns 404 (route no longer exists).
- [ ] Staging smoke test passes with a real MCP client.
- [ ] Production env vars cleaned up.
- [ ] Design doc and this implementation plan committed.
