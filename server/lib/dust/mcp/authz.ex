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
