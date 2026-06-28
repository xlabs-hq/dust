defmodule DustWeb.ApiPrincipal do
  @moduledoc """
  Abstraction over "who is making this API call." Two concrete forms:

    * `:bearer` — request authenticated via API token. `store_token`
      identifies a single store and carries explicit read/write
      permissions.
    * `:session` — request authenticated via the web session cookie.
      `user` is the logged-in user; `organization` is the org parsed
      from the route. Membership is verified before the principal is
      constructed; permissions track the user's role.

  Controllers read this from `conn.assigns.api_principal` instead of
  branching on the auth flavor. Helpers `can_read?/1`, `can_write?/1`,
  `device_id/1`, and `scopes_store?/2` keep the controller code
  agnostic to which path got us here.
  """

  alias Dust.AccessTokens
  alias Dust.AccessTokens.Token

  @type t :: %__MODULE__{
          type: :bearer | :session,
          store_token: Token.t() | nil,
          user: map() | nil,
          organization: map() | nil
        }

  defstruct [:type, :store_token, :user, :organization]

  @doc "Build a bearer-token principal from an authenticated API token."
  @spec from_bearer(Token.t()) :: t()
  def from_bearer(%Token{} = token) do
    %__MODULE__{
      type: :bearer,
      store_token: token,
      organization: token.organization
    }
  end

  @doc """
  Build a session principal from a verified-member user/org pair.
  Membership and role checks happen in the plug *before* this is
  called — the constructor itself doesn't re-verify.
  """
  @spec from_session(map(), map()) :: t()
  def from_session(user, organization) do
    %__MODULE__{
      type: :session,
      user: user,
      organization: organization
    }
  end

  @doc "True if this principal may read entries."
  def can_read?(%__MODULE__{type: :bearer, store_token: t}),
    do: AccessTokens.has_scope?(t, "entries:read")

  # Session users always have read access to their org's stores. Per-store
  # ACLs aren't in this version; refine here if/when they land.
  def can_read?(%__MODULE__{type: :session}), do: true

  @doc "True if this principal may write entries."
  def can_write?(%__MODULE__{type: :bearer, store_token: t}),
    do: AccessTokens.has_scope?(t, "entries:write")

  def can_write?(%__MODULE__{type: :session}), do: true

  @doc """
  True if this principal is scoped to the given store. Bearer tokens
  are pinned to one store; session principals are org-scoped (any
  store in the same org).
  """
  def scopes_store?(%__MODULE__{type: :bearer, store_token: t}, store),
    do: AccessTokens.scopes_store?(t, store)

  def scopes_store?(%__MODULE__{type: :session, organization: org}, store),
    do: org.id == store.organization_id

  def authorize_store(%__MODULE__{type: :bearer, store_token: t}, store, scope),
    do: AccessTokens.authorize_store(t, store, scope)

  def authorize_store(%__MODULE__{type: :session, organization: org}, store, _scope) do
    if org.id == store.organization_id, do: :ok, else: {:error, :store_not_allowed}
  end

  @doc """
  Stable identifier for the writer of an op. Embedded in audit
  records so a forensic reader can tell whether a write came from
  the bearer API or the web UI, and which token/user issued it.
  """
  def device_id(%__MODULE__{type: :bearer, store_token: t}), do: "http:" <> to_string(t.id)
  def device_id(%__MODULE__{type: :session, user: u}), do: "web:" <> to_string(u.id)

  @doc "The organization the principal is operating in."
  def organization(%__MODULE__{organization: org}), do: org
end
