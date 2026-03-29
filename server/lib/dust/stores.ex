defmodule Dust.Stores do
  import Ecto.Query
  alias Dust.Repo
  alias Dust.Stores.{Store, StoreToken, Device}

  @token_prefix "dust_tok_"

  # Stores

  def create_store(organization, attrs) do
    %Store{}
    |> Store.changeset(Map.put(attrs, :organization_id, organization.id))
    |> Repo.insert()
  end

  def get_store!(id), do: Repo.get!(Store, id)

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
    raw_token = generate_token()
    token_hash = hash_token(raw_token)

    permissions = StoreToken.permissions_integer(
      Map.get(attrs, :read, true),
      Map.get(attrs, :write, false)
    )

    result =
      %StoreToken{}
      |> StoreToken.changeset(%{
        name: attrs.name,
        token_hash: token_hash,
        permissions: permissions,
        expires_at: attrs[:expires_at],
        store_id: store.id,
        created_by_id: attrs[:created_by_id]
      })
      |> Repo.insert()

    case result do
      {:ok, token} -> {:ok, %{token | raw_token: raw_token}}
      error -> error
    end
  end

  def authenticate_token(@token_prefix <> _ = raw_token) do
    token_hash = hash_token(raw_token)

    from(t in StoreToken,
      where: t.token_hash == ^token_hash,
      where: is_nil(t.expires_at) or t.expires_at > ^DateTime.utc_now(),
      preload: [store: :organization]
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid_token}
      token ->
        Repo.update(Ecto.Changeset.change(token, last_used_at: DateTime.utc_now()))
        {:ok, token}
    end
  end

  def authenticate_token(_), do: {:error, :invalid_token}

  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token)
  end

  # Devices

  def ensure_device(device_id, user_id \\ nil) do
    case Repo.get_by(Device, device_id: device_id) do
      nil ->
        %Device{}
        |> Device.changeset(%{device_id: device_id, user_id: user_id, last_seen_at: DateTime.utc_now()})
        |> Repo.insert()

      device ->
        device
        |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
        |> Repo.update()
    end
  end
end
