defmodule Dust.MCP.Authz do
  @moduledoc """
  Authorizes store access for an MCP principal.

  Single entry point used by every MCP tool. Handles both principal kinds
  (legacy store_token, OAuth user_session) so tools don't branch on the kind.
  """

  alias Dust.AccessTokens
  alias Dust.Accounts
  alias Dust.MCP.Principal
  alias Dust.Stores

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
    scope = scope_for(permission)

    case AccessTokens.authorize_store(token, store, scope) do
      :ok ->
        :ok

      {:error, :store_not_allowed} ->
        {:error, "Token does not have access to store"}

      {:error, {:missing_scope, scope}} ->
        {:error, "Token is missing #{permission} permission (#{scope} scope)"}
    end
  end

  defp check_principal(%Principal{kind: :user_session, user: user}, store, _permission) do
    if Accounts.user_belongs_to_org?(user, store.organization_id) do
      :ok
    else
      {:error, "User does not have access to this store"}
    end
  end

  defp scope_for(:read), do: "entries:read"
  defp scope_for(:write), do: "entries:write"
end
