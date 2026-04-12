# MCP OAuth + Tool Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add OAuth 2.1 + DCR to the existing `/mcp` endpoint (so Claude Desktop / Cursor / ChatGPT can autoconfigure) and add five new MCP tools (`create_store`, `export`, `diff`, `import`, `clone`) to reach feature parity with the CLI.

**Architecture:** Dust acts as both the OAuth resource server and authorization server. WorkOS AuthKit is the upstream identity provider. MCP sessions are stored in `mcp_sessions` (Postgres), opaque bearer tokens are SHA-256 hashed at rest, expiry is 30 days sliding. Sessions are user-scoped (not org-scoped) — store access flows through `user → membership → organization → store`. Pattern mirrors `/Users/james/Desktop/elixir/root` with two deltas: no org binding, and sliding expiry.

**Tech Stack:** Elixir 1.15, Phoenix 1.8, Ecto, PostgreSQL, GenMCP 0.8, WorkOS Elixir SDK, Jason.

**Reference design doc:** `docs/plans/2026-04-12-mcp-oauth-design.md` — read this first.

**Working directory:** All paths below are relative to the repository root (`/Users/james/Desktop/elixir/dust`). The Phoenix project lives in `server/`. All `mix` commands run from `server/`.

---

## Pre-flight

Before starting, read these files end-to-end so you understand existing patterns:

1. `docs/plans/2026-04-12-mcp-oauth-design.md` — design rationale.
2. `server/lib/dust_web/router.ex` — current `/mcp` scope, `:mcp` pipeline.
3. `server/lib/dust_web/plugs/mcp_auth.ex` — current bearer-only plug.
4. `server/lib/dust/mcp/tools/dust_get.ex` — exemplar of an existing tool, including `resolve_store/2`.
5. `server/lib/dust/stores/store_token.ex` — `can_read?/can_write?` helpers, `permissions_integer/2`.
6. `server/lib/dust/accounts.ex` — existing `Accounts` context (`list_user_organizations/1`, `ensure_membership/3`).
7. `server/lib/dust_web/controllers/workos_auth_controller.ex` — read `find_or_create_user/1` and `authenticate_with_code` usage; we will reuse this.
8. `/Users/james/Desktop/elixir/root/lib/root_web/controllers/mcp_auth_controller.ex` — reference OAuth controller.
9. `/Users/james/Desktop/elixir/root/lib/root/mcp/session.ex` — reference session schema/context.
10. `/Users/james/Desktop/elixir/root/lib/root_web/plugs/mcp_auth.ex` — reference auth plug.

**Do NOT copy root code wholesale.** Adapt to Dust's conventions: no `try`/`rescue` (CLAUDE.md rule), tagged tuples + `with` chains, one alias per line, aliases at top.

**Existing test patterns:** `server/test/dust/mcp/tools_test.exs` shows the harness used for MCP tool tests. Mirror it.

---

## Phase 0 — Foundation

### Task 0.1: Add `user_belongs_to_org?/2` to Accounts

**Files:**
- Modify: `server/lib/dust/accounts.ex`
- Test: `server/test/dust/accounts_test.exs` (create if absent)

**Step 1: Write the failing test**

```elixir
# server/test/dust/accounts_test.exs
defmodule Dust.AccountsTest do
  use Dust.DataCase, async: true

  alias Dust.Accounts

  describe "user_belongs_to_org?/2" do
    test "returns true when membership exists" do
      user = Dust.AccountsFixtures.user_fixture()
      org = Dust.AccountsFixtures.organization_fixture()
      Accounts.ensure_membership(user, org)

      assert Accounts.user_belongs_to_org?(user, org.id)
    end

    test "returns false when no membership" do
      user = Dust.AccountsFixtures.user_fixture()
      org = Dust.AccountsFixtures.organization_fixture()

      refute Accounts.user_belongs_to_org?(user, org.id)
    end
  end
end
```

If `Dust.AccountsFixtures` doesn't exist or lacks `user_fixture`/`organization_fixture`, look in `server/test/support/fixtures/` for the actual module names and adjust. **Do not create new fixtures** — reuse what's there.

**Step 2: Run test → expect failure**

```bash
cd server && mix test test/dust/accounts_test.exs
```

Expected: `(UndefinedFunctionError) function Dust.Accounts.user_belongs_to_org?/2 is undefined`

**Step 3: Implement**

Add to `server/lib/dust/accounts.ex` near `list_user_organizations/1`:

```elixir
def user_belongs_to_org?(%User{id: user_id}, org_id) when is_binary(org_id) do
  Repo.exists?(
    from m in OrganizationMembership,
      where: m.user_id == ^user_id and m.organization_id == ^org_id
  )
end
```

**Step 4: Run test → expect pass**

```bash
cd server && mix test test/dust/accounts_test.exs
```

**Step 5: Commit**

```bash
git add server/lib/dust/accounts.ex server/test/dust/accounts_test.exs
git commit -m "feat(accounts): add user_belongs_to_org?/2"
```

---

### Task 0.2: Extract `find_or_create_user_from_workos/1` into Accounts

The OAuth callback will need this; today the logic lives privately in `WorkOSAuthController`. Extract it so both controllers share one path.

**Files:**
- Modify: `server/lib/dust/accounts.ex`
- Modify: `server/lib/dust_web/controllers/workos_auth_controller.ex` (replace local `find_or_create_user/1` with delegate)
- Test: `server/test/dust/accounts_test.exs`

**Step 1: Read the current `find_or_create_user/1` in `workos_auth_controller.ex`** so you know its signature and shape (it accepts a `%WorkOS.UserManagement.User{}` and returns `{:ok, %User{}}`).

**Step 2: Write the failing test** — happy path only (the workos struct interaction is hard to mock; integration is fine):

```elixir
test "find_or_create_user_from_workos/1 creates new user when not present" do
  workos_user = %WorkOS.UserManagement.User{
    id: "user_test_#{System.unique_integer([:positive])}",
    email: "newmcp@example.com",
    first_name: "New",
    last_name: "MCP"
  }

  assert {:ok, user} = Dust.Accounts.find_or_create_user_from_workos(workos_user)
  assert user.email == "newmcp@example.com"
  assert user.workos_id == workos_user.id
end

test "find_or_create_user_from_workos/1 returns existing user by workos_id" do
  workos_user = %WorkOS.UserManagement.User{
    id: "user_existing_#{System.unique_integer([:positive])}",
    email: "exists@example.com",
    first_name: "Ex",
    last_name: "Ist"
  }

  {:ok, first} = Dust.Accounts.find_or_create_user_from_workos(workos_user)
  {:ok, second} = Dust.Accounts.find_or_create_user_from_workos(workos_user)
  assert first.id == second.id
end
```

**Step 3: Run → fail (`UndefinedFunctionError`)**

**Step 4: Implement** — port `find_or_create_user/1` from `workos_auth_controller.ex` verbatim into `Dust.Accounts.find_or_create_user_from_workos/1`. Then in the controller, replace its private `find_or_create_user(workos_user)` body with `Dust.Accounts.find_or_create_user_from_workos(workos_user)`. Keep the wrapper to avoid touching every call site, or sed-replace all call sites — your choice.

**Step 5: Run → pass.** Then run the WorkOS controller tests to make sure the delegate didn't break anything:

```bash
cd server && mix test test/dust_web/controllers/workos_auth_controller_test.exs
```

**Step 6: Commit**

```bash
git add server/lib/dust/accounts.ex server/lib/dust_web/controllers/workos_auth_controller.ex server/test/dust/accounts_test.exs
git commit -m "refactor(accounts): extract find_or_create_user_from_workos/1"
```

---

## Phase 1 — Session schema & context

### Task 1.1: Migration for `mcp_sessions`

**Files:**
- Create: `server/priv/repo/migrations/YYYYMMDDHHMMSS_create_mcp_sessions.exs`

**Step 1: Generate the migration**

```bash
cd server && mix ecto.gen.migration create_mcp_sessions
```

**Step 2: Fill in the migration body**

```elixir
defmodule Dust.Repo.Migrations.CreateMcpSessions do
  use Ecto.Migration

  def change do
    create table(:mcp_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :access_token_hash, :string
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :client_name, :string
      add :client_version, :string
      add :remote_ip, :string
      add :user_agent, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :last_activity_at, :utc_datetime_usec, null: false
      add :invalidated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_sessions, [:session_id])
    create unique_index(:mcp_sessions, [:access_token_hash])
    create index(:mcp_sessions, [:user_id])
    create index(:mcp_sessions, [:expires_at])
  end
end
```

Verify `users` table primary key is `binary_id` first by checking another migration that references it.

**Step 3: Run migration**

```bash
cd server && mix ecto.migrate
```

**Step 4: Commit**

```bash
git add server/priv/repo/migrations/*_create_mcp_sessions.exs
git commit -m "feat(mcp): add mcp_sessions migration"
```

---

### Task 1.2: `Dust.MCP.Session` schema

**Files:**
- Create: `server/lib/dust/mcp/session.ex`

**Step 1: Write the schema (no test — pure data; tests come with the context module).**

```elixir
defmodule Dust.MCP.Session do
  use Dust.Schema

  alias Dust.Accounts.User

  schema "mcp_sessions" do
    field :session_id, :string
    field :access_token_hash, :string
    field :client_name, :string
    field :client_version, :string
    field :remote_ip, :string
    field :user_agent, :string
    field :expires_at, :utc_datetime_usec
    field :last_activity_at, :utc_datetime_usec
    field :invalidated_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> Ecto.Changeset.cast(attrs, [
      :session_id,
      :access_token_hash,
      :user_id,
      :client_name,
      :client_version,
      :remote_ip,
      :user_agent,
      :expires_at,
      :last_activity_at,
      :invalidated_at
    ])
    |> Ecto.Changeset.validate_required([:session_id, :user_id, :expires_at, :last_activity_at])
    |> Ecto.Changeset.unique_constraint(:session_id)
    |> Ecto.Changeset.unique_constraint(:access_token_hash)
  end
end
```

Confirm `Dust.Schema` provides `binary_id` PK by reading another schema (e.g. `Dust.Stores.Store`).

**Step 2: Compile**

```bash
cd server && mix compile --warnings-as-errors
```

**Step 3: Commit**

```bash
git add server/lib/dust/mcp/session.ex
git commit -m "feat(mcp): add Session schema"
```

---

### Task 1.3: `Dust.MCP.Sessions` context — `create_for_user/2` + `hash_token/1`

**Files:**
- Create: `server/lib/dust/mcp/sessions.ex`
- Test: `server/test/dust/mcp/sessions_test.exs`

**Step 1: Write the failing tests**

```elixir
defmodule Dust.MCP.SessionsTest do
  use Dust.DataCase, async: true

  alias Dust.MCP.Sessions

  describe "create_for_user/2" do
    test "creates a session with session_id and 30-day expiry" do
      user = Dust.AccountsFixtures.user_fixture()
      assert {:ok, session} = Sessions.create_for_user(user, %{})
      assert String.starts_with?(session.session_id, "mcp_")
      assert is_nil(session.access_token_hash)
      assert DateTime.diff(session.expires_at, DateTime.utc_now(), :day) >= 29
    end

    test "captures client metadata" do
      user = Dust.AccountsFixtures.user_fixture()
      attrs = %{client_name: "Claude Desktop", client_version: "0.7.1", remote_ip: "1.2.3.4"}
      assert {:ok, session} = Sessions.create_for_user(user, attrs)
      assert session.client_name == "Claude Desktop"
      assert session.client_version == "0.7.1"
      assert session.remote_ip == "1.2.3.4"
    end
  end

  describe "hash_token/1" do
    test "is stable and lowercase hex" do
      assert Sessions.hash_token("hello") == Sessions.hash_token("hello")
      assert Sessions.hash_token("hello") =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
```

**Step 2: Run → fail.**

**Step 3: Implement**

```elixir
defmodule Dust.MCP.Sessions do
  @moduledoc "Context for MCP OAuth sessions: create, look up, slide expiry, invalidate."

  import Ecto.Query

  alias Dust.Repo
  alias Dust.MCP.Session

  @token_lifetime_seconds 30 * 86_400
  @slide_threshold_seconds 60 * 60

  def create_for_user(user, attrs) do
    now = DateTime.utc_now()

    base = %{
      session_id: "mcp_" <> Ecto.UUID.generate(),
      user_id: user.id,
      expires_at: DateTime.add(now, @token_lifetime_seconds, :second),
      last_activity_at: now
    }

    %Session{}
    |> Session.changeset(Map.merge(base, attrs))
    |> Repo.insert()
  end

  def hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
```

**Step 4: Run → pass.**

**Step 5: Commit**

```bash
git add server/lib/dust/mcp/sessions.ex server/test/dust/mcp/sessions_test.exs
git commit -m "feat(mcp): add Sessions.create_for_user and hash_token"
```

---

### Task 1.4: `Sessions.set_access_token/1`

**Files:**
- Modify: `server/lib/dust/mcp/sessions.ex`
- Modify: `server/test/dust/mcp/sessions_test.exs`

**Step 1: Write the failing test**

```elixir
describe "set_access_token/1" do
  test "generates raw token, stores hash, refreshes expiry" do
    user = Dust.AccountsFixtures.user_fixture()
    {:ok, session} = Sessions.create_for_user(user, %{})

    assert {:ok, raw_token, updated} = Sessions.set_access_token(session)
    assert String.length(raw_token) >= 32
    assert updated.access_token_hash == Sessions.hash_token(raw_token)
    assert DateTime.diff(updated.expires_at, DateTime.utc_now(), :day) >= 29
  end
end
```

**Step 2: Run → fail.**

**Step 3: Implement**

```elixir
def set_access_token(%Session{} = session) do
  raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  hash = hash_token(raw_token)
  expires_at = DateTime.add(DateTime.utc_now(), @token_lifetime_seconds, :second)

  case session
       |> Session.changeset(%{access_token_hash: hash, expires_at: expires_at})
       |> Repo.update() do
    {:ok, updated} -> {:ok, raw_token, updated}
    {:error, changeset} -> {:error, changeset}
  end
end
```

**Step 4: Run → pass. Step 5: Commit**

```bash
git add server/lib/dust/mcp/sessions.ex server/test/dust/mcp/sessions_test.exs
git commit -m "feat(mcp): add Sessions.set_access_token"
```

---

### Task 1.5: `Sessions.find_by_session_id/1`, `find_by_access_token_hash/1`

**Files:** same as 1.4

**Step 1: Tests**

```elixir
describe "find_by_session_id/1" do
  test "returns session, ignoring invalidated rows" do
    user = Dust.AccountsFixtures.user_fixture()
    {:ok, session} = Sessions.create_for_user(user, %{})
    assert %Session{} = Sessions.find_by_session_id(session.session_id)

    {:ok, _} = Sessions.invalidate(session)
    assert is_nil(Sessions.find_by_session_id(session.session_id))
  end
end

describe "find_by_access_token_hash/1" do
  test "returns session for current hash, not after invalidation" do
    user = Dust.AccountsFixtures.user_fixture()
    {:ok, session} = Sessions.create_for_user(user, %{})
    {:ok, raw, _} = Sessions.set_access_token(session)

    found = Sessions.find_by_access_token_hash(Sessions.hash_token(raw))
    assert found.id == session.id

    Sessions.invalidate(found)
    assert is_nil(Sessions.find_by_access_token_hash(Sessions.hash_token(raw)))
  end
end
```

**Step 2: Run → fail.**

**Step 3: Implement** (add to `sessions.ex`)

```elixir
def find_by_session_id(session_id) when is_binary(session_id) do
  from(s in Session,
    where: s.session_id == ^session_id and is_nil(s.invalidated_at),
    preload: [:user]
  )
  |> Repo.one()
end

def find_by_access_token_hash(hash) when is_binary(hash) do
  from(s in Session,
    where: s.access_token_hash == ^hash and is_nil(s.invalidated_at),
    preload: [:user]
  )
  |> Repo.one()
end

def invalidate(%Session{} = session) do
  session
  |> Session.changeset(%{invalidated_at: DateTime.utc_now()})
  |> Repo.update()
end
```

**Step 4: Run → pass. Step 5: Commit**

```bash
git add server/lib/dust/mcp/sessions.ex server/test/dust/mcp/sessions_test.exs
git commit -m "feat(mcp): add Sessions lookup and invalidate"
```

---

### Task 1.6: `Sessions.touch_and_slide/1` (sliding expiry)

**Files:** same

**Step 1: Tests**

```elixir
describe "touch_and_slide/1" do
  test "always bumps last_activity_at" do
    user = Dust.AccountsFixtures.user_fixture()
    {:ok, session} = Sessions.create_for_user(user, %{})
    {:ok, raw, session} = Sessions.set_access_token(session)
    {:ok, found} = {:ok, Sessions.find_by_access_token_hash(Sessions.hash_token(raw))}

    # Force last_activity_at into the past
    {:ok, stale} =
      found
      |> Ecto.Changeset.change(last_activity_at: DateTime.add(DateTime.utc_now(), -120, :second))
      |> Dust.Repo.update()

    {:ok, touched} = Sessions.touch_and_slide(stale)
    assert DateTime.compare(touched.last_activity_at, stale.last_activity_at) == :gt
  end

  test "extends expires_at when remaining lifetime is less than 29d" do
    user = Dust.AccountsFixtures.user_fixture()
    {:ok, session} = Sessions.create_for_user(user, %{})
    {:ok, _, session} = Sessions.set_access_token(session)

    # Roll expires_at back to 28 days from now (within slide window)
    short_expiry = DateTime.add(DateTime.utc_now(), 28 * 86_400, :second)
    {:ok, narrowed} =
      session
      |> Ecto.Changeset.change(expires_at: short_expiry)
      |> Dust.Repo.update()

    {:ok, slid} = Sessions.touch_and_slide(narrowed)
    assert DateTime.diff(slid.expires_at, DateTime.utc_now(), :day) >= 29
  end

  test "does NOT extend expires_at when remaining lifetime is still close to 30d" do
    user = Dust.AccountsFixtures.user_fixture()
    {:ok, session} = Sessions.create_for_user(user, %{})
    {:ok, _, session} = Sessions.set_access_token(session)

    {:ok, slid} = Sessions.touch_and_slide(session)
    assert DateTime.diff(slid.expires_at, session.expires_at, :second) |> abs() < 5
  end
end
```

**Step 2: Run → fail.**

**Step 3: Implement**

```elixir
def touch_and_slide(%Session{} = session) do
  now = DateTime.utc_now()
  remaining = DateTime.diff(session.expires_at, now, :second)
  full_lifetime = @token_lifetime_seconds
  slide? = remaining < full_lifetime - @slide_threshold_seconds

  attrs =
    if slide? do
      %{
        last_activity_at: now,
        expires_at: DateTime.add(now, full_lifetime, :second)
      }
    else
      %{last_activity_at: now}
    end

  session
  |> Session.changeset(attrs)
  |> Repo.update()
end
```

Note the threshold: we slide if remaining < `30d - 1h`. That throttles the write to once per hour per session under steady traffic.

**Step 4: Run → pass. Step 5: Commit**

```bash
git add server/lib/dust/mcp/sessions.ex server/test/dust/mcp/sessions_test.exs
git commit -m "feat(mcp): add Sessions.touch_and_slide for sliding expiry"
```

---

## Phase 2 — Authorization substrate

### Task 2.1: `Dust.MCP.Principal` struct

**Files:**
- Create: `server/lib/dust/mcp/principal.ex`

**Step 1: Write**

```elixir
defmodule Dust.MCP.Principal do
  @moduledoc """
  Unified authentication principal for the MCP endpoint.

  `:store_token` — legacy single-store bearer (`dust_tok_…`).
  `:user_session` — OAuth-issued opaque token bound to a user (multi-org).
  """

  defstruct [:kind, :user, :store_token, :session]

  @type kind :: :store_token | :user_session

  @type t :: %__MODULE__{
          kind: kind(),
          user: Dust.Accounts.User.t() | nil,
          store_token: Dust.Stores.StoreToken.t() | nil,
          session: Dust.MCP.Session.t() | nil
        }
end
```

**Step 2: Compile, Step 3: Commit**

```bash
cd server && mix compile --warnings-as-errors
git add server/lib/dust/mcp/principal.ex
git commit -m "feat(mcp): add Principal struct"
```

---

### Task 2.2: `Dust.MCP.Authz.authorize_store/3`

**Files:**
- Create: `server/lib/dust/mcp/authz.ex`
- Test: `server/test/dust/mcp/authz_test.exs`

**Step 1: Tests** — covers both principal kinds and both permission levels:

```elixir
defmodule Dust.MCP.AuthzTest do
  use Dust.DataCase, async: true

  alias Dust.MCP.{Authz, Principal}

  setup do
    user = Dust.AccountsFixtures.user_fixture()
    org = Dust.AccountsFixtures.organization_fixture()
    Dust.Accounts.ensure_membership(user, org)
    {:ok, store} = Dust.Stores.create_store(org, %{name: "alpha"})

    %{user: user, org: org, store: store}
  end

  describe "user_session principal" do
    test "allows read on store in user's org", %{user: user, org: org, store: store} do
      principal = %Principal{kind: :user_session, user: user}
      assert {:ok, ^store} = Authz.authorize_store(principal, "#{org.slug}/#{store.name}", :read)
    end

    test "allows write on store in user's org", %{user: user, org: org, store: store} do
      principal = %Principal{kind: :user_session, user: user}
      assert {:ok, ^store} = Authz.authorize_store(principal, "#{org.slug}/#{store.name}", :write)
    end

    test "denies access when user not in org", %{store: store, org: org} do
      stranger = Dust.AccountsFixtures.user_fixture()
      principal = %Principal{kind: :user_session, user: stranger}
      assert {:error, _} = Authz.authorize_store(principal, "#{org.slug}/#{store.name}", :read)
    end

    test "errors when store not found", %{user: user} do
      principal = %Principal{kind: :user_session, user: user}
      assert {:error, _} = Authz.authorize_store(principal, "nope/missing", :read)
    end
  end

  describe "store_token principal" do
    test "allows when token matches store and has read permission", %{org: org, store: store, user: user} do
      {:ok, %{token: token}} = Dust.Stores.create_store_token(store, %{name: "t", read: true, write: false}, user)
      principal = %Principal{kind: :store_token, store_token: token}
      assert {:ok, ^store} = Authz.authorize_store(principal, "#{org.slug}/#{store.name}", :read)
    end

    test "denies write on read-only token", %{org: org, store: store, user: user} do
      {:ok, %{token: token}} = Dust.Stores.create_store_token(store, %{name: "t", read: true, write: false}, user)
      principal = %Principal{kind: :store_token, store_token: token}
      assert {:error, _} = Authz.authorize_store(principal, "#{org.slug}/#{store.name}", :write)
    end
  end
end
```

**Note:** the exact API for `Dust.Stores.create_store_token/3` may differ — read `server/lib/dust/stores.ex` and adjust the test setup accordingly. Look at how existing tool tests construct store tokens (`server/test/dust/mcp/tools_test.exs`) and copy that pattern verbatim.

**Step 2: Run → fail.**

**Step 3: Implement**

```elixir
defmodule Dust.MCP.Authz do
  @moduledoc """
  Authorizes store access for an MCP principal.

  Single entry point used by every MCP tool. Handles both principal kinds
  (legacy store_token, OAuth user_session) so tools don't branch on the kind.
  """

  alias Dust.Accounts
  alias Dust.MCP.Principal
  alias Dust.Stores
  alias Dust.Stores.StoreToken

  @type permission :: :read | :write

  @spec authorize_store(Principal.t(), String.t(), permission()) ::
          {:ok, Stores.Store.t()} | {:error, String.t()}
  def authorize_store(%Principal{} = principal, full_name, permission)
      when permission in [:read, :write] do
    with {:ok, store} <- find_store(full_name),
         :ok <- check_principal(principal, store, permission) do
      {:ok, store}
    end
  end

  defp find_store(full_name) do
    case Stores.get_store_by_full_name(full_name) do
      nil -> {:error, "Store not found: #{full_name}"}
      store -> {:ok, store}
    end
  end

  defp check_principal(%Principal{kind: :store_token, store_token: token}, store, permission) do
    cond do
      token.store_id != store.id ->
        {:error, "Token does not have access to store"}

      not has_permission?(token, permission) ->
        {:error, "Token does not have #{permission} permission"}

      true ->
        :ok
    end
  end

  defp check_principal(%Principal{kind: :user_session, user: user}, store, _permission) do
    if Accounts.user_belongs_to_org?(user, store.organization_id) do
      :ok
    else
      {:error, "User does not have access to this store"}
    end
  end

  defp has_permission?(token, :read), do: StoreToken.can_read?(token)
  defp has_permission?(token, :write), do: StoreToken.can_write?(token)
end
```

**Step 4: Run → pass. Step 5: Commit**

```bash
git add server/lib/dust/mcp/authz.ex server/test/dust/mcp/authz_test.exs
git commit -m "feat(mcp): add Authz.authorize_store unified principal check"
```

---

### Task 2.3: Update `MCPAuth` plug — accept session tokens, slide expiry, set Principal

**Files:**
- Modify: `server/lib/dust_web/plugs/mcp_auth.ex`
- Test: `server/test/dust_web/plugs/mcp_auth_test.exs` (create)

**Step 1: Tests**

```elixir
defmodule DustWeb.Plugs.MCPAuthTest do
  use DustWeb.ConnCase, async: true

  alias Dust.MCP.{Principal, Sessions}
  alias DustWeb.Plugs.MCPAuth

  describe "MCPAuth plug" do
    test "401 + WWW-Authenticate when no token" do
      conn = build_conn() |> MCPAuth.call(MCPAuth.init([]))
      assert conn.status == 401
      assert conn.halted
      [www] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert www =~ "Bearer"
      assert www =~ "resource_metadata="
      assert www =~ "/.well-known/oauth-protected-resource"
    end

    test "401 when bearer token is unknown" do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer not_a_real_token")
        |> MCPAuth.call(MCPAuth.init([]))

      assert conn.status == 401
      assert conn.halted
    end

    test "accepts legacy dust_tok_ store token and sets store_token principal" do
      # Construct via the same fixture path as existing tools_test.exs
      %{token: raw_token, store_token: store_token} = mcp_store_token_fixture()

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw_token}")
        |> MCPAuth.call(MCPAuth.init([]))

      refute conn.halted
      principal = conn.assigns.mcp_principal
      assert %Principal{kind: :store_token} = principal
      assert principal.store_token.id == store_token.id
      # Legacy assign retained for back-compat:
      assert conn.assigns.store_token.id == store_token.id
    end

    test "accepts OAuth session token and sets user_session principal" do
      user = Dust.AccountsFixtures.user_fixture()
      {:ok, session} = Sessions.create_for_user(user, %{})
      {:ok, raw, _} = Sessions.set_access_token(session)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
        |> MCPAuth.call(MCPAuth.init([]))

      refute conn.halted
      principal = conn.assigns.mcp_principal
      assert %Principal{kind: :user_session} = principal
      assert principal.user.id == user.id
    end

    test "rejects expired session token" do
      user = Dust.AccountsFixtures.user_fixture()
      {:ok, session} = Sessions.create_for_user(user, %{})
      {:ok, raw, session} = Sessions.set_access_token(session)

      session
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Dust.Repo.update!()

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
        |> MCPAuth.call(MCPAuth.init([]))

      assert conn.status == 401
      assert conn.halted
    end
  end

  defp mcp_store_token_fixture do
    # Inline-port whatever helper tools_test.exs uses to mint a store_token.
    # Read server/test/dust/mcp/tools_test.exs and copy the pattern here.
    raise "TODO: port store_token fixture from tools_test.exs"
  end
end
```

**Important:** the placeholder helper above needs to be replaced with whatever pattern `tools_test.exs` already uses. Read that file first; do not invent a new fixture.

**Step 2: Run → fail.**

**Step 3: Rewrite the plug**

```elixir
defmodule DustWeb.Plugs.MCPAuth do
  @moduledoc """
  Authenticates MCP requests via Bearer token.

  Accepts two token kinds:

    1. Legacy single-store tokens (`dust_tok_…`) authenticated via
       `Dust.Stores.authenticate_token/1`.
    2. OAuth-issued opaque session tokens authenticated via
       `Dust.MCP.Sessions.find_by_access_token_hash/1`. These slide their
       expiry on each successful request.

  On success, sets `:mcp_principal` (and a legacy `:store_token` assign for
  back-compat). On failure, returns 401 with a `WWW-Authenticate` challenge
  pointing at the protected resource metadata endpoint.
  """

  import Plug.Conn

  alias Dust.MCP.Principal
  alias Dust.MCP.Sessions
  alias Dust.Stores

  def init(opts), do: opts

  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, %Principal{} = principal} ->
        conn
        |> assign(:mcp_principal, principal)
        |> assign_legacy(principal)

      {:error, message} ->
        send_unauthorized(conn, message)
    end
  end

  defp authenticate(conn) do
    with {:ok, raw} <- extract_bearer(conn),
         {:ok, principal} <- principal_for(raw) do
      {:ok, principal}
    end
  end

  defp principal_for("dust_tok_" <> _ = raw) do
    case Stores.authenticate_token(raw) do
      {:ok, store_token} ->
        {:ok, %Principal{kind: :store_token, store_token: store_token}}

      _ ->
        {:error, "invalid token"}
    end
  end

  defp principal_for(raw) do
    hash = Sessions.hash_token(raw)

    case Sessions.find_by_access_token_hash(hash) do
      nil ->
        {:error, "invalid token"}

      session ->
        if expired?(session) do
          {:error, "token expired"}
        else
          {:ok, slid} = Sessions.touch_and_slide(session)
          {:ok, %Principal{kind: :user_session, user: slid.user, session: slid}}
        end
    end
  end

  defp expired?(session) do
    DateTime.compare(session.expires_at, DateTime.utc_now()) != :gt
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, "missing bearer token"}
    end
  end

  defp assign_legacy(conn, %Principal{kind: :store_token, store_token: token}) do
    assign(conn, :store_token, token)
  end

  defp assign_legacy(conn, _principal), do: conn

  defp send_unauthorized(conn, message) do
    base_url = Application.get_env(:dust, :mcp_base_url, DustWeb.Endpoint.url())

    challenge =
      ~s(Bearer error="unauthorized", error_description="#{message}", resource_metadata="#{base_url}/.well-known/oauth-protected-resource")

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized", error_description: message}))
    |> halt()
  end
end
```

**Step 4: Run → pass. Step 5: Commit**

```bash
git add server/lib/dust_web/plugs/mcp_auth.ex server/test/dust_web/plugs/mcp_auth_test.exs
git commit -m "feat(mcp): plug accepts user-session tokens with sliding expiry"
```

---

### Task 2.4: Migrate the 13 existing tools to use Authz + Principal

**Files (modify each):**
- `server/lib/dust/mcp/tools/dust_get.ex`
- `server/lib/dust/mcp/tools/dust_put.ex`
- `server/lib/dust/mcp/tools/dust_merge.ex`
- `server/lib/dust/mcp/tools/dust_delete.ex`
- `server/lib/dust/mcp/tools/dust_enum.ex`
- `server/lib/dust/mcp/tools/dust_increment.ex`
- `server/lib/dust/mcp/tools/dust_add.ex`
- `server/lib/dust/mcp/tools/dust_remove.ex`
- `server/lib/dust/mcp/tools/dust_stores.ex`
- `server/lib/dust/mcp/tools/dust_status.ex`
- `server/lib/dust/mcp/tools/dust_log.ex`
- `server/lib/dust/mcp/tools/dust_put_file.ex`
- `server/lib/dust/mcp/tools/dust_fetch_file.ex`

This is mechanical. The pattern in each tool's `call/3`:

```elixir
# BEFORE
store_token = channel.assigns.store_token
with {:ok, store} <- resolve_store(store_name, store_token) do
  ...
end

defp resolve_store(full_name, store_token), do: ...
```

**AFTER**

```elixir
principal = channel.assigns.mcp_principal
with {:ok, store} <- Dust.MCP.Authz.authorize_store(principal, store_name, :read) do
  ...
end
```

Drop the local `resolve_store/2` and the permission-bit check entirely. Use `:read` for read-only tools (Get, Enum, Stores, Status, Log, FetchFile) and `:write` for the rest.

**Special cases:**

- **`DustStores`** doesn't take a `store` argument — it lists stores. For a `:user_session` principal, list stores across all the user's orgs (use `Dust.Accounts.list_user_organizations/1`). For a `:store_token` principal, it should list only the one store the token grants access to (current behavior). Keep the kind-branch local to this tool.
- **`DustStatus`** also takes no store; if it currently returns the store_token's store, branch the same way: `:store_token` → return that store's status; `:user_session` → require an explicit `store` argument and route through `Authz`.
- **`DustLog`** takes a `store` arg already? Verify and route through `Authz`.

**Step 1: Migrate one tool first as a template** — pick `DustGet`.

```elixir
defmodule Dust.MCP.Tools.DustGet do
  @moduledoc "MCP tool: read a value at a path in a store."

  use GenMCP.Suite.Tool,
    name: "dust_get",
    description:
      "Read a value at a path in a Dust store. Returns the entry value or null if not found.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"},
        path: %{type: :string, description: "Dot-separated path to read (e.g. \"users.alice\")"}
      },
      required: [:store, :path]
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"store" => store_name, "path" => path} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, store_name, :read) do
      result =
        case Dust.Sync.get_entry(store.id, path) do
          nil -> nil
          entry -> entry.value
        end

      {:result, MCP.call_tool_result(text: Jason.encode!(result)), channel}
    else
      {:error, reason} -> {:error, reason, channel}
    end
  end
end
```

**Step 2: Run existing tool tests**

```bash
cd server && mix test test/dust/mcp/tools_test.exs
```

If the tool tests construct a `store_token` and pass it via `channel.assigns.store_token`, you'll need to update them to also set `:mcp_principal`. Check what the test harness does. If many tests need updating, write a small `mcp_test_helper` that builds a `Principal` and use it from the suite.

**Step 3: Migrate the remaining 12 tools the same way.** Run `mix test test/dust/mcp/tools_test.exs` after each one. Don't batch — one tool per commit so any regression bisects cleanly.

**Step 4: Final compile pass**

```bash
cd server && mix compile --warnings-as-errors
```

**Step 5: Commit (one commit per migrated tool)**

```bash
git add server/lib/dust/mcp/tools/dust_get.ex
git commit -m "refactor(mcp): dust_get uses Authz principal"
# repeat for each
```

---

## Phase 3 — OAuth controller & router

### Task 3.1: Config + base URL helper

**Files:**
- Modify: `server/config/runtime.exs`
- Modify: `server/config/dev.exs` (or `config.exs`) for dev defaults

**Step 1: Edit `runtime.exs`**

Inside the `if config_env() == :prod do` block (or wherever WorkOS config currently lives — match the file's existing pattern), add:

```elixir
config :dust, :mcp_base_url,
  System.get_env("MCP_BASE_URL") || "https://#{System.get_env("PHX_HOST")}"

config :dust, :authkit_base_url,
  System.fetch_env!("AUTHKIT_BASE_URL")

config :workos, :mcp_client_id,
  System.fetch_env!("WORKOS_MCP_CLIENT_ID")
```

**Step 2: Add dev defaults** in `config/dev.exs`:

```elixir
config :dust, :mcp_base_url, "http://localhost:7755"
config :dust, :authkit_base_url, System.get_env("AUTHKIT_BASE_URL", "")
config :workos, :mcp_client_id, System.get_env("WORKOS_MCP_CLIENT_ID", "client_dev_unconfigured")
```

**Step 3: Compile**

```bash
cd server && mix compile
```

**Step 4: Commit**

```bash
git add server/config/runtime.exs server/config/dev.exs
git commit -m "feat(mcp): add OAuth runtime config keys"
```

**Note:** The `WORKOS_MCP_CLIENT_ID` env var requires creating a second OAuth client in the WorkOS dashboard with redirect URI `<MCP_BASE_URL>/oauth/callback`. This is a manual operator step — note it in the README task at the end.

---

### Task 3.2: OAuth metadata controller — discovery endpoints

**Files:**
- Create: `server/lib/dust_web/controllers/mcp_auth_controller.ex`
- Test: `server/test/dust_web/controllers/mcp_auth_controller_test.exs`

**Step 1: Tests**

```elixir
defmodule DustWeb.MCPAuthControllerTest do
  use DustWeb.ConnCase, async: true

  describe "GET /.well-known/oauth-protected-resource" do
    test "returns RFC 9728 metadata", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/oauth-protected-resource")
      body = json_response(conn, 200)
      assert is_binary(body["resource"])
      assert is_list(body["authorization_servers"])
      assert hd(body["authorization_servers"]) == body["resource"]
      assert "header" in body["bearer_methods_supported"]
    end
  end

  describe "GET /.well-known/oauth-authorization-server" do
    test "returns RFC 8414 metadata", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)
      assert is_binary(body["issuer"])
      assert body["authorization_endpoint"] =~ "/oauth/authorize"
      assert body["token_endpoint"] =~ "/oauth/token"
      assert body["registration_endpoint"] =~ "/register"
      assert "S256" in body["code_challenge_methods_supported"]
      assert "authorization_code" in body["grant_types_supported"]
    end
  end
end
```

**Step 2: Run → fail (no route).**

**Step 3: Implement controller (only metadata actions for this task)**

```elixir
defmodule DustWeb.MCPAuthController do
  use DustWeb, :controller

  require Logger

  def oauth_protected_resource(conn, _params) do
    base = base_url()

    json(conn, %{
      resource: base,
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
      resource_documentation: base
    })
  end

  def oauth_authorization_server(conn, _params) do
    base = base_url()

    json(conn, %{
      issuer: base,
      authorization_endpoint: "#{base}/oauth/authorize",
      token_endpoint: "#{base}/oauth/token",
      registration_endpoint: "#{base}/register",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["profile", "email"]
    })
  end

  defp base_url do
    Application.fetch_env!(:dust, :mcp_base_url)
  end
end
```

**Step 4: Wire routes** — modify `server/lib/dust_web/router.ex`. Add a new pipeline above the `/mcp` scope:

```elixir
pipeline :mcp_oauth do
  plug :accepts, ["json", "html"]
  plug :fetch_session
end

scope "/", DustWeb do
  pipe_through :mcp_oauth

  get "/.well-known/oauth-protected-resource", MCPAuthController, :oauth_protected_resource
  get "/.well-known/oauth-authorization-server", MCPAuthController, :oauth_authorization_server
end
```

Place this scope **above** the `/:org` catch-all scope to avoid shadowing.

**Step 5: Run → pass.**

```bash
cd server && mix test test/dust_web/controllers/mcp_auth_controller_test.exs
```

**Step 6: Commit**

```bash
git add server/lib/dust_web/controllers/mcp_auth_controller.ex server/lib/dust_web/router.ex server/test/dust_web/controllers/mcp_auth_controller_test.exs
git commit -m "feat(mcp): add OAuth discovery metadata endpoints"
```

---

### Task 3.3: `POST /register` (Dynamic Client Registration)

**Files:** same controller, same test

**Step 1: Test**

```elixir
describe "POST /register" do
  test "returns the configured WorkOS MCP client_id", %{conn: conn} do
    payload = %{
      "client_name" => "Claude Desktop",
      "redirect_uris" => ["http://localhost:33418/oauth/callback"],
      "grant_types" => ["authorization_code"],
      "response_types" => ["code"]
    }

    conn = post(conn, ~p"/register", payload)
    body = json_response(conn, 200)

    assert is_binary(body["client_id"])
    assert body["client_id"] == Application.fetch_env!(:workos, :mcp_client_id)
    assert body["redirect_uris"] == payload["redirect_uris"]
    assert "authorization_code" in body["grant_types"]
  end
end
```

**Step 2: Implement**

```elixir
def register(conn, params) do
  client_id = Application.fetch_env!(:workos, :mcp_client_id)

  response = %{
    client_id: client_id,
    client_name: params["client_name"],
    redirect_uris: params["redirect_uris"] || [],
    grant_types: params["grant_types"] || ["authorization_code"],
    response_types: params["response_types"] || ["code"],
    token_endpoint_auth_method: params["token_endpoint_auth_method"] || "none",
    authorization_endpoint: "#{base_url()}/oauth/authorize",
    token_endpoint: "#{base_url()}/oauth/token"
  }

  json(conn, response)
end
```

**Step 3: Add route** to the `:mcp_oauth` scope:

```elixir
post "/register", MCPAuthController, :register
```

**Step 4: Run → pass. Step 5: Commit**

```bash
git add server/lib/dust_web/controllers/mcp_auth_controller.ex server/lib/dust_web/router.ex server/test/dust_web/controllers/mcp_auth_controller_test.exs
git commit -m "feat(mcp): add /register Dynamic Client Registration endpoint"
```

---

### Task 3.4: `GET /oauth/authorize`

**Files:** same controller, same test, modify router

**Step 1: Test**

```elixir
describe "GET /oauth/authorize" do
  test "stores client params in session and redirects to AuthKit", %{conn: conn} do
    Application.put_env(:dust, :authkit_base_url, "https://test.authkit.app")

    params = %{
      "response_type" => "code",
      "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
      "redirect_uri" => "http://localhost:33418/oauth/callback",
      "state" => "client_state_123",
      "code_challenge" => "abc123def456",
      "code_challenge_method" => "S256",
      "scope" => "profile email"
    }

    conn = get(conn, ~p"/oauth/authorize", params)
    assert redirected_to(conn, 302) =~ "https://test.authkit.app/oauth2/authorize"

    location = redirected_to(conn, 302)
    assert location =~ "code_challenge="
    assert location =~ "redirect_uri=" <> URI.encode_www_form("#{Application.fetch_env!(:dust, :mcp_base_url)}/oauth/callback")
    assert location =~ "state=oauth_flow_client_state_123"

    # Session must capture client params for the callback
    stored = get_session(conn, :oauth_params)
    assert stored.redirect_uri == "http://localhost:33418/oauth/callback"
    assert stored.code_challenge == "abc123def456"
    assert get_session(conn, :code_verifier)
  end

  test "400 on missing params", %{conn: conn} do
    conn = get(conn, ~p"/oauth/authorize", %{})
    assert json_response(conn, 400)["error"] == "invalid_request"
  end
end
```

**Step 2: Implement**

```elixir
def oauth_authorize(conn, %{
      "response_type" => _,
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "state" => state,
      "code_challenge" => challenge,
      "code_challenge_method" => method
    } = params) do
  oauth_state =
    if String.starts_with?(state, "oauth_flow_") do
      state
    else
      "oauth_flow_" <> state
    end

  conn =
    conn
    |> put_session(:oauth_params, %{
      client_id: client_id,
      redirect_uri: redirect_uri,
      state: oauth_state,
      code_challenge: challenge,
      code_challenge_method: method,
      scope: Map.get(params, "scope", "")
    })

  # Mint our own PKCE for the upstream WorkOS exchange
  upstream_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  upstream_challenge = :crypto.hash(:sha256, upstream_verifier) |> Base.url_encode64(padding: false)
  conn = put_session(conn, :code_verifier, upstream_verifier)

  query =
    URI.encode_query(%{
      client_id: Application.fetch_env!(:workos, :mcp_client_id),
      response_type: "code",
      redirect_uri: "#{base_url()}/oauth/callback",
      scope: "profile email",
      state: oauth_state,
      code_challenge: upstream_challenge,
      code_challenge_method: "S256"
    })

  authkit = Application.fetch_env!(:dust, :authkit_base_url)
  redirect(conn, external: "#{authkit}/oauth2/authorize?#{query}")
end

def oauth_authorize(conn, _params) do
  conn
  |> put_status(:bad_request)
  |> json(%{
    error: "invalid_request",
    error_description: "Missing required OAuth parameters"
  })
end
```

**Step 3: Add route**

```elixir
get "/oauth/authorize", MCPAuthController, :oauth_authorize
```

**Step 4: Run → pass. Step 5: Commit**

```bash
git add ...
git commit -m "feat(mcp): add /oauth/authorize endpoint"
```

---

### Task 3.5: `GET /oauth/callback`

**Files:** same

The tricky part: this calls WorkOS to exchange the code. Look at how `WorkOSAuthController.callback/2` does it (probably `WorkOS.UserManagement.authenticate_with_code/1`). Use the same call.

**Step 1: Test** — stub the WorkOS call. If the project doesn't already have a WorkOS test stub pattern, **add one**:

- Define `Dust.WorkOSClient` behaviour (single function: `authenticate_with_code/1`).
- Default impl delegates to `WorkOS.UserManagement.authenticate_with_code/1`.
- Mock impl in test config returns canned data.

This may be too disruptive — first **check whether `DustWeb.WorkOSAuthController` is already tested with stubbed WorkOS calls**, and reuse that pattern. If not, mark it as a separate decision point and ask before introducing a new abstraction. **STOP HERE and ask the user if a behaviour-based stub doesn't already exist**.

Assuming a stub exists, the test:

```elixir
describe "GET /oauth/callback" do
  setup do
    user = Dust.AccountsFixtures.user_fixture()
    Dust.WorkOSStub.set_response(%{user: user_to_workos_struct(user)})
    %{user: user}
  end

  test "creates session, redirects to client redirect_uri with code=session_id", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(%{
        oauth_params: %{
          client_id: "client_dev",
          redirect_uri: "http://localhost:33418/oauth/callback",
          state: "oauth_flow_state123",
          code_challenge: "client_challenge",
          code_challenge_method: "S256",
          scope: ""
        },
        code_verifier: "upstream_verifier"
      })
      |> get(~p"/oauth/callback?code=workos_code&state=oauth_flow_state123")

    location = redirected_to(conn, 302)
    assert location =~ "http://localhost:33418/oauth/callback"
    assert location =~ "code=mcp_"
    assert location =~ "state=state123"

    code = location |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("code")
    session = Dust.MCP.Sessions.find_by_session_id(code)
    assert session.user_id == user.id
    assert is_nil(session.access_token_hash)
  end
end
```

**Step 2: Implement**

```elixir
def oauth_callback(conn, %{"code" => code} = params) do
  oauth_params = get_session(conn, :oauth_params) || %{}
  code_verifier = get_session(conn, :code_verifier)
  client_redirect = oauth_params[:redirect_uri]
  stored_state = oauth_params[:state] || ""
  callback_state = Map.get(params, "state", "")

  cond do
    is_nil(code_verifier) ->
      json_error(conn, :bad_request, "missing_session", "Missing PKCE verifier")

    is_nil(client_redirect) ->
      json_error(conn, :bad_request, "missing_redirect_uri", "Missing client redirect_uri")

    stored_state != callback_state ->
      json_error(conn, :bad_request, "state_mismatch", "State does not match")

    true ->
      do_callback(conn, code, oauth_params, client_redirect, stored_state)
  end
end

defp do_callback(conn, code, _oauth_params, client_redirect, stored_state) do
  with {:ok, %{user: workos_user}} <-
         WorkOS.UserManagement.authenticate_with_code(%{
           client_id: Application.fetch_env!(:workos, :mcp_client_id),
           code: code
         }),
       {:ok, user} <- Dust.Accounts.find_or_create_user_from_workos(workos_user),
       {:ok, session} <-
         Dust.MCP.Sessions.create_for_user(user, %{
           remote_ip: peer_ip(conn),
           user_agent: user_agent(conn)
         }) do
    original_state = String.replace_prefix(stored_state, "oauth_flow_", "")
    callback_url = build_callback_url(client_redirect, session.session_id, original_state)
    redirect(conn, external: callback_url)
  else
    {:error, reason} ->
      Logger.error("MCP oauth_callback failed: #{inspect(reason)}")
      json_error(conn, :unauthorized, "authentication_failed", "Could not authenticate")
  end
end

defp build_callback_url(redirect_uri, code, state) do
  uri = URI.parse(redirect_uri)
  existing = if uri.query, do: URI.decode_query(uri.query), else: %{}
  query = existing |> Map.put("code", code) |> Map.put("state", state) |> URI.encode_query()
  %{uri | query: query} |> URI.to_string()
end

defp peer_ip(conn) do
  case conn.remote_ip do
    {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
    _ -> nil
  end
end

defp user_agent(conn) do
  case Plug.Conn.get_req_header(conn, "user-agent") do
    [ua | _] -> ua
    _ -> nil
  end
end

defp json_error(conn, status, error, description) do
  conn
  |> put_status(status)
  |> json(%{error: error, error_description: description})
end
```

**Step 3: Route**

```elixir
get "/oauth/callback", MCPAuthController, :oauth_callback
```

**Step 4: Run → pass. Step 5: Commit.**

```bash
git commit -m "feat(mcp): add /oauth/callback endpoint"
```

---

### Task 3.6: `POST /oauth/token`

**Step 1: Test**

```elixir
describe "POST /oauth/token" do
  test "exchanges session_id for opaque bearer token", %{conn: conn} do
    user = Dust.AccountsFixtures.user_fixture()
    {:ok, session} = Dust.MCP.Sessions.create_for_user(user, %{})

    conn =
      post(conn, ~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => session.session_id,
        "code_verifier" => "client_verifier",
        "client_id" => Application.fetch_env!(:workos, :mcp_client_id),
        "redirect_uri" => "http://localhost:33418/oauth/callback"
      })

    body = json_response(conn, 200)
    assert is_binary(body["access_token"])
    assert body["token_type"] == "Bearer"
    assert body["expires_in"] > 86_400
  end

  test "rejects already-consumed session_id" do
    # ... call /oauth/token twice with same code, expect second to be invalid_grant
  end

  test "rejects unsupported grant_type" do
    conn = post(build_conn(), ~p"/oauth/token", %{"grant_type" => "client_credentials"})
    assert json_response(conn, 400)["error"] == "unsupported_grant_type"
  end
end
```

**Step 2: Implement**

```elixir
def oauth_token(conn, %{"grant_type" => "authorization_code", "code" => code}) do
  case Dust.MCP.Sessions.find_by_session_id(code) do
    %Dust.MCP.Session{access_token_hash: nil} = session ->
      case Dust.MCP.Sessions.set_access_token(session) do
        {:ok, raw, updated} ->
          expires_in = DateTime.diff(updated.expires_at, DateTime.utc_now(), :second) |> max(0)

          json(conn, %{
            access_token: raw,
            token_type: "Bearer",
            expires_in: expires_in,
            scope: "profile email"
          })

        {:error, _} ->
          json_error(conn, :internal_server_error, "server_error", "Failed to issue token")
      end

    %Dust.MCP.Session{} ->
      json_error(conn, :bad_request, "invalid_grant", "Authorization code already used")

    nil ->
      json_error(conn, :bad_request, "invalid_grant", "Invalid authorization code")
  end
end

def oauth_token(conn, _params) do
  json_error(conn, :bad_request, "unsupported_grant_type", "Only authorization_code is supported")
end
```

**Step 3: Route**

```elixir
post "/oauth/token", MCPAuthController, :oauth_token
```

**Step 4: Run → pass. Step 5: Commit**

```bash
git commit -m "feat(mcp): add /oauth/token endpoint"
```

---

## Phase 4 — New tools (CLI parity)

Each tool follows the same pattern: define schema, implement `call/3`, write a happy-path + auth-denial test, commit. Reuse the existing tool tests in `server/test/dust/mcp/tools_test.exs` as the harness template.

### Task 4.1: `Dust.MCP.Tools.DustCreateStore`

**Files:**
- Create: `server/lib/dust/mcp/tools/dust_create_store.ex`
- Modify: `server/test/dust/mcp/tools_test.exs`
- Modify: `server/lib/dust_web/router.ex` (add to `tools:` list)

**Step 1: Test**

```elixir
test "dust_create_store creates store under user's org" do
  # Use whatever fixture pattern the existing tests use; minimum:
  user = Dust.AccountsFixtures.user_fixture()
  org = Dust.AccountsFixtures.organization_fixture()
  Dust.Accounts.ensure_membership(user, org)

  result = call_tool(Dust.MCP.Tools.DustCreateStore,
    %{"org" => org.slug, "name" => "fresh"},
    user_session_principal(user)
  )

  assert {:result, %{content: [%{text: text}]}, _} = result
  decoded = Jason.decode!(text)
  assert decoded["store"] == "#{org.slug}/fresh"
end

test "dust_create_store denies when user not in org" do
  user = Dust.AccountsFixtures.user_fixture()
  org = Dust.AccountsFixtures.organization_fixture()  # no membership

  assert {:error, _, _} = call_tool(Dust.MCP.Tools.DustCreateStore,
    %{"org" => org.slug, "name" => "fresh"},
    user_session_principal(user)
  )
end
```

`call_tool/3` and `user_session_principal/1` are helpers you'll add to the test file (or to a shared `Dust.MCP.TestHelpers` module). They build a minimal `channel` struct with `:mcp_principal` set.

**Step 2: Implement**

```elixir
defmodule Dust.MCP.Tools.DustCreateStore do
  @moduledoc "MCP tool: create a new store under an organization."

  use GenMCP.Suite.Tool,
    name: "dust_create_store",
    description: "Create a new Dust store under an organization the caller belongs to.",
    input_schema: %{
      type: :object,
      properties: %{
        org: %{type: :string, description: "Organization slug"},
        name: %{type: :string, description: "New store name"}
      },
      required: [:org, :name]
    }

  alias Dust.Accounts
  alias Dust.MCP.Principal
  alias Dust.Stores
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"org" => org_slug, "name" => name} = req.params.arguments

    with {:ok, org} <- find_org(org_slug),
         :ok <- check_membership(channel.assigns.mcp_principal, org),
         {:ok, store} <- Stores.create_store(org, %{name: name}) do
      payload = %{store: "#{org.slug}/#{store.name}", id: store.id}
      {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
    else
      {:error, reason} -> {:error, to_string_reason(reason), channel}
    end
  end

  defp find_org(slug) do
    case Accounts.get_organization_by_slug(slug) do
      nil -> {:error, "Organization not found: #{slug}"}
      org -> {:ok, org}
    end
  end

  defp check_membership(%Principal{kind: :user_session, user: user}, org) do
    if Accounts.user_belongs_to_org?(user, org.id), do: :ok, else: {:error, "Not a member of #{org.slug}"}
  end

  defp check_membership(%Principal{kind: :store_token}, _org) do
    {:error, "Store tokens cannot create new stores"}
  end

  defp to_string_reason(%Ecto.Changeset{} = cs), do: inspect(cs.errors)
  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end
```

Confirm `Dust.Accounts.get_organization_by_slug/1` exists (vs `get_organization_by_slug!/1`); if only the bang version exists, add the non-bang version, or `try`-free with `Repo.get_by`.

**Step 3: Add to router `tools:` list**

**Step 4: Run → pass. Step 5: Commit**

```bash
git commit -m "feat(mcp): add dust_create_store tool"
```

---

### Task 4.2: `Dust.MCP.Tools.DustExport`

**Files:**
- Create: `server/lib/dust/mcp/tools/dust_export.ex`
- Modify test + router

**Step 1: Test**

```elixir
test "dust_export returns jsonl payload for user-session principal" do
  user = ...
  org = ...
  Accounts.ensure_membership(user, org)
  {:ok, store} = Stores.create_store(org, %{name: "alpha"})
  Dust.Sync.put_entry(store.id, "users.alice", %{"age" => 30}, "test")

  {:result, %{content: [%{text: text}]}, _} =
    call_tool(Dust.MCP.Tools.DustExport,
      %{"store" => "#{org.slug}/alpha"},
      user_session_principal(user))

  payload = Jason.decode!(text)
  assert is_list(payload["lines"])
  assert payload["full_name"] == "#{org.slug}/alpha"
end
```

**Step 2: Implement**

```elixir
defmodule Dust.MCP.Tools.DustExport do
  @moduledoc "MCP tool: export a store as JSONL."

  use GenMCP.Suite.Tool,
    name: "dust_export",
    description: "Export a Dust store as a JSONL document. Capped at 1 MB.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string, description: "Full store name (org/store)"}
      },
      required: [:store]
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias Dust.Sync
  alias GenMCP.MCP

  @max_bytes 1_048_576

  @impl true
  def call(req, channel, _arg) do
    %{"store" => full_name} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, full_name, :read) do
      lines = Sync.Export.to_jsonl_lines(store.id, full_name)
      body = Enum.join(lines, "\n")

      if byte_size(body) > @max_bytes do
        {:error, "Store too large for MCP transport (#{byte_size(body)} bytes); use the CLI: dust export #{full_name}", channel}
      else
        payload = %{full_name: full_name, lines: lines}
        {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
      end
    else
      {:error, reason} -> {:error, reason, channel}
    end
  end
end
```

**Step 3-5: Test, route entry, commit.**

```bash
git commit -m "feat(mcp): add dust_export tool"
```

---

### Task 4.3: `Dust.MCP.Tools.DustDiff`

Same shape as Export. Inputs: `store`, `from_seq`, optional `to_seq`. Read permission. Wraps `Dust.Sync.Diff.changes/3`.

```elixir
defmodule Dust.MCP.Tools.DustDiff do
  use GenMCP.Suite.Tool,
    name: "dust_diff",
    description: "Get the diff of changes between two store sequence numbers.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string},
        from_seq: %{type: :integer, description: "Starting sequence number (inclusive)"},
        to_seq: %{type: :integer, description: "Optional ending sequence number"}
      },
      required: [:store, :from_seq]
    },
    annotations: %{readOnlyHint: true}

  alias Dust.MCP.Authz
  alias Dust.Sync
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    args = req.params.arguments
    full_name = args["store"]
    from_seq = args["from_seq"]
    to_seq = args["to_seq"]
    principal = channel.assigns.mcp_principal

    with {:ok, store} <- Authz.authorize_store(principal, full_name, :read),
         {:ok, diff} <- Sync.Diff.changes(store.id, from_seq, to_seq) do
      payload = %{
        from_seq: diff.from_seq,
        to_seq: diff.to_seq,
        changes:
          Enum.map(diff.changes, fn c ->
            %{path: c.path, before: c.before, after: c.after}
          end)
      }

      {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason, channel}
      {:error, :compacted, _} -> {:error, "Diff range has been compacted; use a more recent from_seq", channel}
      {:error, reason} -> {:error, inspect(reason), channel}
    end
  end
end
```

**Test, route, commit.**

```bash
git commit -m "feat(mcp): add dust_diff tool"
```

---

### Task 4.4: `Dust.MCP.Tools.DustImport`

Inputs: `store`, `payload` (string of newline-joined JSONL — match the existing import controller's body format). Write permission. 1 MB cap on input.

```elixir
defmodule Dust.MCP.Tools.DustImport do
  use GenMCP.Suite.Tool,
    name: "dust_import",
    description: "Import JSONL entries into a Dust store. Payload capped at 1 MB.",
    input_schema: %{
      type: :object,
      properties: %{
        store: %{type: :string},
        payload: %{type: :string, description: "Newline-joined JSONL export payload"}
      },
      required: [:store, :payload]
    }

  alias Dust.MCP.Authz
  alias Dust.Sync
  alias GenMCP.MCP

  @max_bytes 1_048_576

  @impl true
  def call(req, channel, _arg) do
    %{"store" => full_name, "payload" => payload} = req.params.arguments
    principal = channel.assigns.mcp_principal

    cond do
      byte_size(payload) > @max_bytes ->
        {:error, "Payload too large (#{byte_size(payload)} bytes); use the CLI: dust import", channel}

      true ->
        with {:ok, store} <- Authz.authorize_store(principal, full_name, :write) do
          lines = String.split(payload, "\n")
          {:ok, count} = Sync.Import.from_jsonl(store.id, lines, "mcp:#{principal_label(principal)}")
          {:result, MCP.call_tool_result(text: Jason.encode!(%{ok: true, entries_imported: count})), channel}
        else
          {:error, reason} -> {:error, reason, channel}
        end
    end
  end

  defp principal_label(%{kind: :user_session, user: user}), do: "user:#{user.id}"
  defp principal_label(%{kind: :store_token, store_token: t}), do: "token:#{t.id}"
end
```

**Test, route, commit.**

```bash
git commit -m "feat(mcp): add dust_import tool"
```

---

### Task 4.5: `Dust.MCP.Tools.DustClone`

Inputs: `source_store` (`org/store`), `target_org`, `target_name`. Read on source, write/membership on target.

**Important caveat:** the existing `Dust.Sync.Clone.clone_store/3` takes `(source_store, organization, target_name)` — same-org-only. For multi-org cloning we need either:

1. **Option A:** verify the function signature actually handles cross-org (read its source).
2. **Option B:** add a new arity `Sync.Clone.clone_store/4` that accepts a target org distinct from source org.
3. **Option C:** scope the MCP tool to same-org clones only for v1 and document the limitation.

**Read `server/lib/dust/sync/clone.ex` first** and decide. If Option C is the simplest path, the MCP tool only takes `source_store` and `target_name`, cloning under the same org. Note this in the tool description and add it to the open-items list at the bottom of the implementation plan.

Assuming Option C for v1:

```elixir
defmodule Dust.MCP.Tools.DustClone do
  use GenMCP.Suite.Tool,
    name: "dust_clone",
    description: "Clone a Dust store within the same organization.",
    input_schema: %{
      type: :object,
      properties: %{
        source: %{type: :string, description: "Source store, full name (org/store)"},
        target_name: %{type: :string, description: "New store name"}
      },
      required: [:source, :target_name]
    }

  alias Dust.MCP.Authz
  alias Dust.Repo
  alias Dust.Sync
  alias GenMCP.MCP

  @impl true
  def call(req, channel, _arg) do
    %{"source" => source_full, "target_name" => target_name} = req.params.arguments
    principal = channel.assigns.mcp_principal

    with {:ok, source} <- Authz.authorize_store(principal, source_full, :write),
         source = Repo.preload(source, :organization),
         {:ok, target} <- Sync.Clone.clone_store(source, source.organization, target_name) do
      payload = %{store: "#{source.organization.slug}/#{target.name}", id: target.id}
      {:result, MCP.call_tool_result(text: Jason.encode!(payload)), channel}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason, channel}
      {:error, :limit_exceeded, _} -> {:error, "Organization store limit exceeded", channel}
      {:error, reason} -> {:error, inspect(reason), channel}
    end
  end
end
```

**Test, route, commit.**

```bash
git commit -m "feat(mcp): add dust_clone tool"
```

---

### Task 4.6: Wire all 5 tools into the router

**Files:**
- Modify: `server/lib/dust_web/router.ex`

Append to the existing `tools:` list under the `/mcp` forward:

```elixir
Dust.MCP.Tools.DustCreateStore,
Dust.MCP.Tools.DustExport,
Dust.MCP.Tools.DustDiff,
Dust.MCP.Tools.DustImport,
Dust.MCP.Tools.DustClone
```

(If you've been adding them as you go, this task is just verification. Run `mix compile` and then start the server briefly with `mix phx.server` — actually, do NOT start the server (CLAUDE.md rule). Just compile and run the full test suite:

```bash
cd server && mix compile --warnings-as-errors && mix test
```

**Commit any router-only fixups:**

```bash
git commit -m "feat(mcp): register all five new tools in router"
```

---

## Phase 5 — Polish

### Task 5.1: Run the full precommit gauntlet

```bash
cd server && mix precommit
```

Fix any warnings, formatter issues, or unused-deps that the alias surfaces. Commit any cleanup.

```bash
git commit -m "chore(mcp): precommit cleanup"
```

---

### Task 5.2: Document the OAuth endpoints in AGENTS.md

**Files:**
- Modify: `server/AGENTS.md`

Add a brief section at the bottom (under `## FINAL NOTE`'s neighbors, or wherever fits):

```markdown
## MCP OAuth

The MCP server at `/mcp` accepts two authentication methods:

1. **Legacy bearer tokens** (`dust_tok_…`) for programmatic use — single-store scoped.
2. **OAuth 2.1 + DCR** for MCP clients (Claude Desktop, Cursor, ChatGPT) —
   user-scoped, multi-org, 30-day sliding expiry.

Discovery endpoints:
- `GET /.well-known/oauth-protected-resource`
- `GET /.well-known/oauth-authorization-server`
- `POST /register` (DCR)
- `GET /oauth/authorize`
- `GET /oauth/callback`
- `POST /oauth/token`

To wire Claude Desktop: add an MCP server with URL `https://<host>/mcp`. The
client will discover the OAuth endpoints automatically.

**Operator setup:** create a second WorkOS OAuth client dedicated to MCP
(redirect URI `<MCP_BASE_URL>/oauth/callback`), set
`WORKOS_MCP_CLIENT_ID` and `AUTHKIT_BASE_URL` env vars.
```

**Commit**

```bash
git add server/AGENTS.md
git commit -m "docs(mcp): document OAuth endpoints and operator setup"
```

---

### Task 5.3: Final integration test — full happy path

**Files:**
- Create: `server/test/dust_web/mcp_oauth_integration_test.exs`

**Step 1: Write a single end-to-end test**

```elixir
defmodule DustWeb.MCPOAuthIntegrationTest do
  use DustWeb.ConnCase, async: false

  test "full OAuth + tool call happy path" do
    user = Dust.AccountsFixtures.user_fixture()
    org = Dust.AccountsFixtures.organization_fixture()
    Dust.Accounts.ensure_membership(user, org)
    {:ok, _store} = Dust.Stores.create_store(org, %{name: "integration"})

    # 1. Discovery
    conn = build_conn() |> get(~p"/.well-known/oauth-protected-resource")
    assert json_response(conn, 200)["authorization_servers"]

    # 2. DCR
    conn = build_conn() |> post(~p"/register", %{"client_name" => "test", "redirect_uris" => ["http://localhost/cb"]})
    assert json_response(conn, 200)["client_id"]

    # 3. Skip the WorkOS round-trip — directly create a session as if /oauth/callback ran
    {:ok, session} = Dust.MCP.Sessions.create_for_user(user, %{client_name: "test"})

    # 4. Token exchange
    conn =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => session.session_id
      })

    assert %{"access_token" => raw_token} = json_response(conn, 200)

    # 5. Use the token against /mcp dust_stores tool
    # (Use whatever helper the existing tool tests use to drive a tool call
    #  via the GenMCP transport — or call the tool directly with a synthetic
    #  channel built from the auth plug result.)
  end
end
```

This test deliberately stubs the WorkOS round-trip — full end-to-end with real WorkOS is operator-validation territory.

**Step 2: Run, fix any gaps, commit**

```bash
git add server/test/dust_web/mcp_oauth_integration_test.exs
git commit -m "test(mcp): integration test for OAuth happy path"
```

---

## Done

At this point you should have:

1. `mcp_sessions` table + Session schema + Sessions context
2. `Dust.MCP.Principal` + `Dust.MCP.Authz` (unified authz)
3. `MCPAuth` plug accepting both token kinds with sliding expiry + WWW-Authenticate
4. 13 existing tools migrated to the unified principal
5. 5 new tools wired up: DustCreateStore, DustExport, DustDiff, DustImport, DustClone
6. OAuth controller + routes for discovery, DCR, authorize, callback, token
7. Config keys for `MCP_BASE_URL`, `AUTHKIT_BASE_URL`, `WORKOS_MCP_CLIENT_ID`
8. AGENTS.md docs
9. Full precommit gauntlet passing

**Open items to surface to the user after implementation:**

- WorkOS dashboard: create the second OAuth client and capture `WORKOS_MCP_CLIENT_ID`.
- If DustClone landed as same-org-only (Option C above), decide whether to extend `Sync.Clone.clone_store/4` for cross-org cloning.
- Manual smoke test from Claude Desktop: add the MCP server URL, complete the OAuth flow, call a tool.

---

## Notes for executor

- **Never use `try`/`rescue`** — tagged tuples + `with` chains only (CLAUDE.md).
- **Never start/stop the Phoenix server** — it's already running via tidewave.
- **One alias per line, all aliases at the top of the file.**
- **Format after each task:** `cd server && mix format`.
- **Commit per task** — bisect-friendly history matters.
- If a step's expected output doesn't match reality, **stop and report** rather than papering over it. Don't introduce abstractions or fixtures that aren't already there — ask first.
- If `Dust.WorkOSStub` or equivalent doesn't already exist for testing OAuth callback (Task 3.5), **stop and ask the user** before introducing a behaviour-based stub.
