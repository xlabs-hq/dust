defmodule Dust.AccessTokens do
  import Ecto.Query

  alias Dust.AccessTokens.ScopeGrant
  alias Dust.AccessTokens.StoreGrant
  alias Dust.AccessTokens.Token
  alias Dust.Accounts.Organization
  alias Dust.Repo
  alias Dust.Stores.Store

  @token_prefix "dust_tok_"
  @read_permission 1
  @write_permission 2

  @scope_definitions [
    %{
      scope: "stores:read",
      label: "List stores",
      description: "See stores this token can access.",
      group: "Stores"
    },
    %{
      scope: "stores:create",
      label: "Create stores",
      description: "Create new stores in the account.",
      group: "Stores"
    },
    %{
      scope: "stores:clone",
      label: "Clone stores",
      description: "Clone accessible stores into new stores.",
      group: "Stores"
    },
    %{
      scope: "entries:read",
      label: "Read entries",
      description: "Read, enumerate, diff, and export store entries.",
      group: "Entries"
    },
    %{
      scope: "entries:write",
      label: "Write entries",
      description: "Create, update, delete, import, lease, and roll back entries.",
      group: "Entries"
    },
    %{
      scope: "files:read",
      label: "Read files",
      description: "Download blobs referenced by accessible stores.",
      group: "Files"
    },
    %{
      scope: "files:write",
      label: "Write files",
      description: "Upload files and attach file references to entries.",
      group: "Files"
    },
    %{
      scope: "webhooks:read",
      label: "Read webhooks",
      description: "List webhooks and delivery attempts.",
      group: "Webhooks"
    },
    %{
      scope: "webhooks:write",
      label: "Write webhooks",
      description: "Create, delete, and test webhooks.",
      group: "Webhooks"
    },
    %{
      scope: "audit:read",
      label: "Read audit log",
      description: "View operation history for accessible stores.",
      group: "Audit"
    },
    %{
      scope: "tokens:read",
      label: "Read tokens",
      description: "List metadata for tokens in this account.",
      group: "Tokens"
    },
    %{
      scope: "tokens:write",
      label: "Write tokens",
      description: "Create, edit, and revoke tokens in this account.",
      group: "Tokens"
    }
  ]

  @valid_scopes MapSet.new(Enum.map(@scope_definitions, & &1.scope))
  @read_scopes ["stores:read", "entries:read", "files:read", "webhooks:read", "audit:read"]

  @write_scopes [
    "stores:clone",
    "entries:write",
    "files:write",
    "webhooks:write",
    "tokens:read",
    "tokens:write"
  ]

  def scope_definitions, do: @scope_definitions
  def valid_scopes, do: MapSet.to_list(@valid_scopes) |> Enum.sort()

  def create_store_token(%Store{} = store, attrs) do
    store = Repo.preload(store, :organization)

    read? = truthy?(get_attr(attrs, :read, true))
    write? = truthy?(get_attr(attrs, :write, false))

    create_token(store.organization, %{
      name: get_attr(attrs, :name),
      scopes: legacy_scopes(read?, write?),
      store_access_mode: :selected,
      store_ids: [store.id],
      expires_at: get_attr(attrs, :expires_at),
      created_by_id: get_attr(attrs, :created_by_id)
    })
  end

  def create_token(%Organization{} = organization, attrs) do
    raw_token = generate_token()
    scope_strings = normalize_scopes(get_attr(attrs, :scopes, []))

    store_access_mode =
      normalize_store_access_mode(get_attr(attrs, :store_access_mode, :selected))

    store_ids = normalize_store_ids(get_attr(attrs, :store_ids, []))

    token_attrs = %{
      name: get_attr(attrs, :name),
      token_hash: hash_token(raw_token),
      token_prefix: "dust_tok",
      token_last4: String.slice(raw_token, -4, 4),
      store_access_mode: store_access_mode,
      expires_at: get_attr(attrs, :expires_at),
      organization_id: organization.id,
      created_by_id: get_attr(attrs, :created_by_id)
    }

    changeset =
      %Token{}
      |> Token.changeset(token_attrs)
      |> validate_scopes(scope_strings)
      |> validate_store_ids(organization, store_access_mode, store_ids)

    if changeset.valid? do
      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, token} ->
            replace_scopes!(token, scope_strings)
            replace_store_grants!(token, organization, store_access_mode, store_ids)

            token
            |> load_token()
            |> Map.put(:raw_token, raw_token)

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  def update_token(%Token{} = token, %Organization{} = organization, attrs) do
    token = load_token(token)
    scope_strings = normalize_scopes(get_attr(attrs, :scopes, token.scopes))

    store_access_mode =
      normalize_store_access_mode(get_attr(attrs, :store_access_mode, token.store_access_mode))

    store_ids = normalize_store_ids(get_attr(attrs, :store_ids, token.store_ids))

    changeset =
      token
      |> Token.update_changeset(%{
        name: get_attr(attrs, :name, token.name),
        store_access_mode: store_access_mode,
        expires_at: get_attr(attrs, :expires_at, token.expires_at)
      })
      |> validate_token_org(organization)
      |> validate_scopes(scope_strings)
      |> validate_store_ids(organization, store_access_mode, store_ids)

    if changeset.valid? do
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, updated} ->
            replace_scopes!(updated, scope_strings)
            replace_store_grants!(updated, organization, store_access_mode, store_ids)
            load_token(updated)

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  def authenticate_token(@token_prefix <> _ = raw_token) do
    token_hash = hash_token(raw_token)
    now = DateTime.utc_now()

    from(t in Token,
      where: t.token_hash == ^token_hash,
      where: is_nil(t.revoked_at),
      where: is_nil(t.expires_at) or t.expires_at > ^now,
      preload: [:organization, :scope_grants, store_grants: [store: :organization]]
    )
    |> Repo.one()
    |> case do
      nil ->
        {:error, :invalid_token}

      token ->
        {:ok, token} = Repo.update(Ecto.Changeset.change(token, last_used_at: now))
        {:ok, decorate_token(token)}
    end
  end

  def authenticate_token(_), do: {:error, :invalid_token}

  def list_org_tokens(%Organization{} = organization) do
    from(t in Token,
      where: t.organization_id == ^organization.id,
      where: is_nil(t.revoked_at),
      order_by: [desc: t.inserted_at],
      preload: [:organization, :scope_grants, store_grants: [store: :organization]]
    )
    |> Repo.all()
    |> Enum.map(&decorate_token/1)
  end

  def list_store_tokens(store_id) do
    case Repo.get(Store, store_id) do
      nil ->
        []

      store ->
        from(t in Token,
          left_join: g in StoreGrant,
          on: g.token_id == t.id and g.store_id == ^store.id,
          where: t.organization_id == ^store.organization_id,
          where: is_nil(t.revoked_at),
          where: t.store_access_mode == :all or not is_nil(g.token_id),
          order_by: [desc: t.inserted_at],
          preload: [:organization, :scope_grants, store_grants: [store: :organization]]
        )
        |> Repo.all()
        |> Enum.map(&decorate_token/1)
    end
  end

  def list_accessible_stores(%Token{} = token) do
    token = load_token(token)

    case token.store_access_mode do
      :all ->
        from(s in Store,
          where: s.organization_id == ^token.organization_id and s.status == :active,
          order_by: s.name,
          preload: [:organization]
        )
        |> Repo.all()

      :selected ->
        token.store_grants
        |> Enum.map(& &1.store)
        |> Enum.filter(&(&1.status == :active))
        |> Enum.sort_by(& &1.name)
    end
  end

  def find_accessible_store(%Token{} = token, fun) when is_function(fun, 1) do
    token
    |> list_accessible_stores()
    |> Enum.find(fun)
  end

  def list_visible_tokens(%Token{} = caller) do
    caller = load_token(caller)

    if has_scope?(caller, "tokens:read") do
      caller.organization
      |> list_org_tokens()
      |> Enum.filter(&can_manage_token?(caller, &1))
    else
      []
    end
  end

  def can_manage_token?(%Token{} = caller, %Token{} = target) do
    caller = load_token(caller)
    target = load_token(target)

    cond do
      caller.organization_id != target.organization_id ->
        false

      caller.store_access_mode == :all ->
        true

      target.store_access_mode == :all ->
        false

      true ->
        Enum.all?(target.store_ids, &(&1 in caller.store_ids))
    end
  end

  def get_token!(id), do: Repo.get!(Token, id)

  def get_token_in_org(id, %Organization{} = organization) do
    from(t in Token,
      where: t.id == ^id,
      where: t.organization_id == ^organization.id,
      where: is_nil(t.revoked_at),
      preload: [:organization, :scope_grants, store_grants: [store: :organization]]
    )
    |> Repo.one()
    |> case do
      nil -> nil
      token -> decorate_token(token)
    end
  end

  def revoke_token(token_id, revoked_by_id \\ nil) do
    case Repo.get(Token, token_id) do
      nil ->
        {:error, :not_found}

      %Token{} = token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(), revoked_by_id: revoked_by_id)
        |> Repo.update()
    end
  end

  def revoke_token_in_org(token_id, %Organization{} = organization, revoked_by_id \\ nil) do
    case get_token_in_org(token_id, organization) do
      nil -> {:error, :not_found}
      token -> revoke_token(token.id, revoked_by_id)
    end
  end

  def revoke_token_in_store(token_id, store_id) do
    with %Store{} = store <- Repo.get(Store, store_id),
         %Token{} = token <- Repo.get(Token, token_id) do
      token = load_token(token)

      if scopes_store?(token, store) do
        revoke_token(token.id)
      else
        {:error, :forbidden}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def authorize_store(%Token{} = token, %Store{} = store, scope) when is_binary(scope) do
    token = load_token(token)

    cond do
      not scopes_store?(token, store) ->
        {:error, :store_not_allowed}

      not has_scope?(token, scope) ->
        {:error, {:missing_scope, scope}}

      true ->
        :ok
    end
  end

  def authorize_org(%Token{} = token, %Organization{} = organization, scope) do
    token = load_token(token)

    cond do
      token.organization_id != organization.id ->
        {:error, :org_not_allowed}

      not has_scope?(token, scope) ->
        {:error, {:missing_scope, scope}}

      true ->
        :ok
    end
  end

  def scopes_store?(%Token{} = token, %Store{} = store) do
    token = load_token(token)

    case token.store_access_mode do
      :all ->
        token.organization_id == store.organization_id

      :selected ->
        Enum.any?(token.store_grants, &(&1.store_id == store.id))
    end
  end

  def has_scope?(%Token{} = token, scope) when is_binary(scope) do
    token = load_token(token)
    scope in token.scopes
  end

  def can_read?(%Token{} = token), do: has_scope?(token, "entries:read")
  def can_write?(%Token{} = token), do: has_scope?(token, "entries:write")

  def permissions_integer(read?, write?) do
    if(read?, do: @read_permission, else: 0) + if(write?, do: @write_permission, else: 0)
  end

  def capabilities(%Token{} = token) do
    token = load_token(token)

    %{
      scopes: token.scopes,
      permissions: %{
        read: has_scope?(token, "entries:read"),
        write: has_scope?(token, "entries:write")
      },
      store_access: %{
        mode: token.store_access_mode,
        store_ids: token.store_ids
      }
    }
  end

  def capabilities(%Token{} = token, %Store{} = store) do
    token = load_token(token)
    store_allowed? = scopes_store?(token, store)

    %{
      scopes: token.scopes,
      permissions: %{
        read: store_allowed? and has_scope?(token, "entries:read"),
        write: store_allowed? and has_scope?(token, "entries:write")
      },
      store_access: %{
        mode: token.store_access_mode,
        store_ids: token.store_ids
      }
    }
  end

  def can_delegate?(%Token{} = caller, scopes, :all, _store_ids) do
    caller = load_token(caller)
    requested_scopes = normalize_scopes(scopes)

    caller.store_access_mode == :all and
      scopes_subset?(requested_scopes, caller.scopes)
  end

  def can_delegate?(%Token{} = caller, scopes, :selected, store_ids) do
    caller = load_token(caller)
    requested_scopes = normalize_scopes(scopes)
    requested_store_ids = normalize_store_ids(store_ids)

    scopes_subset?(requested_scopes, caller.scopes) and
      Enum.all?(requested_store_ids, &token_can_delegate_store?(caller, &1))
  end

  def load_token(%Token{} = token) do
    token
    |> Repo.preload([:organization, :scope_grants, store_grants: [store: :organization]])
    |> decorate_token()
  end

  def hash_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token)
  end

  def legacy_scopes(read?, write?) do
    []
    |> maybe_add_scopes(read?, @read_scopes)
    |> maybe_add_scopes(write?, @write_scopes)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp replace_scopes!(%Token{} = token, scope_strings) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.delete_all(from(s in ScopeGrant, where: s.token_id == ^token.id))

    entries =
      Enum.map(scope_strings, fn scope ->
        %{token_id: token.id, scope: scope, inserted_at: now, updated_at: now}
      end)

    Repo.insert_all(ScopeGrant, entries)
  end

  defp replace_store_grants!(%Token{} = token, %Organization{} = organization, :all, _store_ids) do
    Repo.delete_all(from(g in StoreGrant, where: g.token_id == ^token.id))
    organization
  end

  defp replace_store_grants!(
         %Token{} = token,
         %Organization{} = organization,
         :selected,
         store_ids
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.delete_all(from(g in StoreGrant, where: g.token_id == ^token.id))

    entries =
      store_ids
      |> Enum.uniq()
      |> Enum.map(fn store_id ->
        %{
          token_id: token.id,
          organization_id: organization.id,
          store_id: store_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(StoreGrant, entries)
  end

  defp validate_token_org(changeset, %Organization{} = organization) do
    token = Ecto.Changeset.apply_changes(changeset)

    if token.organization_id == organization.id do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :organization_id, "does not match token")
    end
  end

  defp validate_scopes(changeset, scopes) do
    invalid = Enum.reject(scopes, &MapSet.member?(@valid_scopes, &1))

    cond do
      scopes == [] ->
        Ecto.Changeset.add_error(changeset, :scopes, "must include at least one scope")

      invalid != [] ->
        Ecto.Changeset.add_error(changeset, :scopes, "include invalid scopes")

      true ->
        changeset
    end
  end

  defp validate_store_ids(changeset, %Organization{} = organization, :selected, store_ids) do
    cond do
      store_ids == [] ->
        Ecto.Changeset.add_error(changeset, :store_ids, "must include at least one store")

      not all_stores_in_org?(organization, store_ids) ->
        Ecto.Changeset.add_error(changeset, :store_ids, "include unknown stores")

      true ->
        changeset
    end
  end

  defp validate_store_ids(changeset, _organization, :all, _store_ids), do: changeset

  defp validate_store_ids(changeset, _organization, _mode, _store_ids) do
    Ecto.Changeset.add_error(changeset, :store_access_mode, "is invalid")
  end

  defp all_stores_in_org?(%Organization{} = organization, store_ids) do
    unique_store_ids = Enum.uniq(store_ids)

    count =
      from(s in Store,
        where: s.organization_id == ^organization.id,
        where: s.id in ^unique_store_ids,
        select: count(s.id)
      )
      |> Repo.one()

    count == length(unique_store_ids)
  end

  defp decorate_token(%Token{} = token) do
    scope_grants = loaded_or_empty(token.scope_grants)
    store_grants = loaded_or_empty(token.store_grants)
    scopes = scope_grants |> Enum.map(& &1.scope) |> Enum.sort()
    store_ids = store_grants |> Enum.map(& &1.store_id) |> Enum.sort()

    single_store =
      case store_grants do
        [%StoreGrant{store: %Store{} = store}] -> store
        _ -> nil
      end

    %{
      token
      | scopes: scopes,
        store_ids: store_ids,
        store_id: single_store && single_store.id,
        store: single_store
    }
  end

  defp scopes_subset?(requested_scopes, caller_scopes) do
    Enum.all?(requested_scopes, &(&1 in caller_scopes))
  end

  defp token_can_delegate_store?(%Token{store_access_mode: :all}, _store_id), do: true

  defp token_can_delegate_store?(%Token{store_access_mode: :selected} = caller, store_id) do
    store_id in caller.store_ids
  end

  defp loaded_or_empty(%Ecto.Association.NotLoaded{}), do: []
  defp loaded_or_empty(value) when is_list(value), do: value

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_scopes(scope) when is_binary(scope), do: normalize_scopes([scope])
  defp normalize_scopes(_), do: []

  defp normalize_store_ids(:all), do: []
  defp normalize_store_ids(nil), do: []

  defp normalize_store_ids(store_ids) when is_list(store_ids) do
    store_ids
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_store_ids(store_id) when is_binary(store_id), do: normalize_store_ids([store_id])
  defp normalize_store_ids(_), do: []

  defp normalize_store_access_mode(:all), do: :all
  defp normalize_store_access_mode("all"), do: :all
  defp normalize_store_access_mode(:selected), do: :selected
  defp normalize_store_access_mode("selected"), do: :selected
  defp normalize_store_access_mode(other), do: other

  defp maybe_add_scopes(scopes, true, extra), do: scopes ++ extra
  defp maybe_add_scopes(scopes, _false, _extra), do: scopes

  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp get_attr(attrs, key, default \\ nil)

  defp get_attr(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp get_attr(_attrs, _key, default), do: default

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]
end
