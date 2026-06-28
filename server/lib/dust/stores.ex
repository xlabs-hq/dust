defmodule Dust.Stores do
  import Ecto.Query
  alias Dust.AccessTokens
  alias Dust.Repo
  alias Dust.Stores.{Device, Store}

  # Stores

  def create_store(organization, attrs) do
    case Dust.Billing.Limits.check_store_count(organization) do
      :ok ->
        attrs = maybe_set_expires_at(attrs)

        case %Store{}
             |> Store.changeset(Map.put(attrs, :organization_id, organization.id))
             |> Repo.insert() do
          {:ok, store} ->
            Dust.Sync.StoreDB.ensure_created(store.id)
            {:ok, store}

          error ->
            error
        end

      {:error, :limit_exceeded, _} = error ->
        error
    end
  end

  defp maybe_set_expires_at(%{ttl: ttl} = attrs) when is_integer(ttl) and ttl > 0 do
    expires_at =
      DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.truncate(:microsecond)

    attrs |> Map.delete(:ttl) |> Map.put(:expires_at, expires_at)
  end

  defp maybe_set_expires_at(%{"ttl" => ttl} = attrs) when is_integer(ttl) and ttl > 0 do
    expires_at =
      DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.truncate(:microsecond)

    attrs |> Map.delete("ttl") |> Map.put(:expires_at, expires_at)
  end

  defp maybe_set_expires_at(attrs), do: attrs

  def get_store!(id), do: Repo.get!(Store, id)

  def store_count(organization) do
    from(s in Store,
      where: s.organization_id == ^organization.id and s.status == :active,
      select: count()
    )
    |> Repo.one()
  end

  def list_stores(organization) do
    from(s in Store,
      where: s.organization_id == ^organization.id,
      order_by: s.name
    )
    |> Repo.all()
  end

  def get_store_by_org_and_name!(organization, name) do
    Repo.one!(
      from(s in Store,
        where: s.organization_id == ^organization.id and s.name == ^name and s.status == :active
      )
    )
  end

  def get_store_by_name(organization, name) do
    Repo.one(
      from(s in Store,
        where: s.organization_id == ^organization.id and s.name == ^name and s.status == :active
      )
    )
  end

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
    AccessTokens.create_store_token(store, attrs)
  end

  def authenticate_token(raw_token), do: AccessTokens.authenticate_token(raw_token)

  def list_org_tokens(organization), do: AccessTokens.list_org_tokens(organization)

  def list_store_tokens(store_id), do: AccessTokens.list_store_tokens(store_id)

  def get_token!(id), do: AccessTokens.get_token!(id)

  def revoke_token(token_id), do: AccessTokens.revoke_token(token_id)

  def revoke_token_in_org(token_id, organization),
    do: AccessTokens.revoke_token_in_org(token_id, organization)

  @doc """
  Revoke a token, but only if it belongs to the given store. Returns
  `{:error, :forbidden}` if the token exists in the same org but a
  different store, and `{:error, :not_found}` if the id is unknown.
  """
  def revoke_token_in_store(token_id, store_id) do
    AccessTokens.revoke_token_in_store(token_id, store_id)
  end

  def get_org_stats(organization) do
    stats =
      from(s in Store,
        where: s.organization_id == ^organization.id,
        select: %{
          stores: count(s.id),
          entries: coalesce(sum(s.entry_count), 0)
        }
      )
      |> Repo.one()

    tokens_count =
      from(t in AccessTokens.Token,
        where: t.organization_id == ^organization.id,
        where: is_nil(t.revoked_at),
        select: count(t.id)
      )
      |> Repo.one()

    %{stores: stats.stores, tokens: tokens_count, entries: stats.entries}
  end

  # Devices

  def ensure_device(device_id, user_id \\ nil) do
    case Repo.get_by(Device, device_id: device_id) do
      nil ->
        %Device{}
        |> Device.changeset(%{
          device_id: device_id,
          user_id: user_id,
          last_seen_at: DateTime.utc_now()
        })
        |> Repo.insert()

      device ->
        device
        |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
        |> Repo.update()
    end
  end
end
