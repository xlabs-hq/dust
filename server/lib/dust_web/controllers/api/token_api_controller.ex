defmodule DustWeb.Api.TokenApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.AccessTokens
  alias Dust.Stores
  alias DustWeb.Api.Refs
  alias DustWeb.ApiPrincipal

  action_fallback DustWeb.Api.FallbackController

  @token_ref Refs.schema("Token")
  @unauthorized Refs.unauthorized()
  @forbidden Refs.forbidden()
  @not_found Refs.not_found()
  @bad_request Refs.bad_request()
  @rate_limited Refs.rate_limited()

  operation(:index,
    operation_id: "tokens.list",
    summary: "List API tokens visible to the caller",
    description:
      "Returns token metadata visible to the caller. Session callers see all active account tokens. Bearer-token callers require `tokens:read` and only see tokens whose store access is within their own delegation boundary.",
    tags: ["Tokens"],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{tokens: %{type: :array, items: @token_ref}},
           required: [:tokens]
         }, description: "List of tokens visible to the caller"},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      too_many_requests: @rate_limited
    ]
  )

  def index(conn, _params) do
    principal = conn.assigns.api_principal
    org = ApiPrincipal.organization(principal)

    with :ok <- authorize_org(principal, org, "tokens:read") do
      tokens = list_tokens_for(principal, org)
      json(conn, %{tokens: Enum.map(tokens, &serialize_token/1)})
    end
  end

  operation(:create,
    operation_id: "tokens.create",
    summary: "Create a new API token",
    description: """
    Creates a scoped API token. Token authority has two dimensions:
    canonical `scopes` and `store_access_mode` (`selected` or `all`).
    For selected store access, pass `store_ids`, `store_names`, or the
    legacy single `store_name`.

    Legacy `read` / `write` booleans are still accepted when `scopes`
    is omitted. They expand to the compatibility scope sets.

    Session callers can create any token in the account. Bearer-token
    callers require `tokens:write` and can delegate only scopes and
    store access they already have.

    The `raw_token` is returned **only on creation** — store it
    immediately. The server keeps a one-way hash and cannot recover
    the plaintext later (unlike the webhook secret, which the server
    retains in order to sign deliveries).
    """,
    tags: ["Tokens"],
    request_body:
      {%{
         type: :object,
         properties: %{
           store_name: %{
             type: :string,
             deprecated: true,
             description:
               "Compatibility single store name for selected access. Prefer `store_names` or `store_ids`."
           },
           store_names: %{
             type: :array,
             items: %{type: :string},
             description: "Store names for selected access."
           },
           store_ids: %{
             type: :array,
             items: %{type: :string, format: :uuid},
             description: "Store IDs for selected access."
           },
           store_access_mode: %{
             type: :string,
             enum: ["selected", "all"],
             default: "selected"
           },
           name: %{type: :string, description: "Human-readable label for the token."},
           scopes: %{
             type: :array,
             items: %{type: :string},
             description:
               "Canonical scopes. Examples: `entries:read`, `entries:write`, `files:read`, `files:write`, `webhooks:read`, `webhooks:write`, `audit:read`, `stores:read`, `stores:clone`, `tokens:read`, `tokens:write`."
           },
           read: %{
             type: :boolean,
             default: true,
             deprecated: true,
             description: "Legacy compatibility flag used only when `scopes` is omitted."
           },
           write: %{
             type: :boolean,
             default: false,
             deprecated: true,
             description: "Legacy compatibility flag used only when `scopes` is omitted."
           }
         },
         required: [:name],
         example: %{
           store_names: ["config"],
           store_access_mode: "selected",
           name: "ci-deploy",
           scopes: ["entries:read", "entries:write"]
         }
       }, description: "Token creation payload"},
    responses: [
      created:
        {%{
           type: :object,
           properties: %{
             id: %{type: :string, format: :uuid},
             name: %{type: :string},
             raw_token: %{
               type: :string,
               description: "Plaintext token. Only returned on creation."
             },
             store_access_mode: %{type: :string, enum: ["all", "selected"]},
             stores: %{
               type: :array,
               items: %{
                 type: :object,
                 properties: %{
                   id: %{type: :string, format: :uuid},
                   name: %{type: :string}
                 },
                 required: [:id, :name]
               }
             },
             scopes: %{type: :array, items: %{type: :string}},
             permissions: %{
               type: :object,
               properties: %{read: %{type: :boolean}, write: %{type: :boolean}},
               required: [:read, :write]
             }
           },
           required: [:id, :name, :raw_token, :store_access_mode, :stores, :scopes, :permissions]
         }, description: "Token created"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @not_found,
      unprocessable_entity: {Refs.schema("ValidationError"), description: "Validation error"},
      too_many_requests: @rate_limited
    ]
  )

  def create(conn, %{"name" => name} = params) do
    principal = conn.assigns.api_principal
    org = ApiPrincipal.organization(principal)

    with :ok <- authorize_org(principal, org, "tokens:write"),
         {:ok, token_attrs} <- token_attrs_from_params(principal, org, name, params),
         :ok <- verify_delegation(principal, token_attrs) do
      create_token(conn, org, token_attrs)
    end
  end

  def create(_conn, _params) do
    {:error, {:invalid_params, "name is required"}}
  end

  defp create_token(conn, org, attrs) do
    case AccessTokens.create_token(org, attrs) do
      {:ok, token} ->
        conn
        |> put_status(201)
        |> json(%{
          id: token.id,
          name: token.name,
          raw_token: token.raw_token,
          store_access_mode: token.store_access_mode,
          stores: serialize_token_stores(token),
          scopes: token.scopes,
          permissions: serialize_permissions(token)
        })

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: format_errors(changeset)})
    end
  end

  operation(:delete,
    operation_id: "tokens.revoke",
    summary: "Revoke an API token",
    description:
      "Revokes a token. Session callers can revoke any account token. Bearer-token callers require `tokens:write` and can revoke only tokens whose store access is within their own delegation boundary.",
    tags: ["Tokens"],
    parameters: [
      id: [in: :path, schema: %{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{ok: %{type: :boolean}},
           required: [:ok]
         }, description: "Token revoked"},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @not_found,
      too_many_requests: @rate_limited
    ]
  )

  def delete(conn, %{"id" => id}) do
    principal = conn.assigns.api_principal
    org = ApiPrincipal.organization(principal)

    with :ok <- authorize_org(principal, org, "tokens:write"),
         {:ok, target} <- find_manageable_token(principal, org, id),
         {:ok, _} <- AccessTokens.revoke_token_in_org(target.id, org) do
      json(conn, %{ok: true})
    end
  end

  defp list_tokens_for(%ApiPrincipal{type: :bearer, store_token: token}, _org) do
    AccessTokens.list_visible_tokens(token)
  end

  defp list_tokens_for(%ApiPrincipal{type: :session}, org), do: AccessTokens.list_org_tokens(org)

  defp find_manageable_token(%ApiPrincipal{type: :session}, org, id) do
    case AccessTokens.get_token_in_org(id, org) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  defp find_manageable_token(%ApiPrincipal{type: :bearer, store_token: caller}, org, id) do
    case AccessTokens.get_token_in_org(id, org) do
      nil ->
        {:error, :not_found}

      target ->
        if AccessTokens.can_manage_token?(caller, target) do
          {:ok, target}
        else
          {:error, :forbidden}
        end
    end
  end

  defp token_attrs_from_params(principal, org, name, params) do
    scopes = scopes_from_params(params)
    mode = store_access_mode_from_params(params)

    with {:ok, store_ids} <- store_ids_from_params(org, mode, params) do
      {:ok,
       %{
         name: name,
         scopes: scopes,
         store_access_mode: mode,
         store_ids: store_ids,
         created_by_id: created_by_id(principal)
       }}
    end
  end

  defp scopes_from_params(%{"scopes" => scopes}) when is_list(scopes), do: scopes

  defp scopes_from_params(params) do
    read? = Map.get(params, "read", true) not in [false, "false", "0", 0]
    write? = Map.get(params, "write", false) in [true, "true", "1", 1]
    AccessTokens.legacy_scopes(read?, write?)
  end

  defp store_access_mode_from_params(%{"store_access_mode" => "all"}), do: :all
  defp store_access_mode_from_params(_params), do: :selected

  defp store_ids_from_params(_org, :all, _params), do: {:ok, []}

  defp store_ids_from_params(org, :selected, params) do
    cond do
      is_list(params["store_ids"]) ->
        {:ok, params["store_ids"]}

      is_list(params["store_names"]) ->
        store_ids_from_names(org, params["store_names"])

      is_binary(params["store_name"]) ->
        store_ids_from_names(org, [params["store_name"]])

      true ->
        {:error, {:invalid_params, "selected store access requires store_ids or store_name"}}
    end
  end

  defp store_ids_from_names(org, store_names) do
    stores =
      Enum.map(store_names, fn store_name ->
        Stores.get_store_by_name(org, store_name)
      end)

    if Enum.any?(stores, &is_nil/1) do
      {:error, :not_found}
    else
      {:ok, Enum.map(stores, & &1.id)}
    end
  end

  defp created_by_id(%ApiPrincipal{type: :bearer, store_token: token}), do: token.created_by_id
  defp created_by_id(%ApiPrincipal{type: :session, user: user}), do: user.id

  defp verify_delegation(%ApiPrincipal{type: :session}, _attrs), do: :ok

  defp verify_delegation(%ApiPrincipal{type: :bearer, store_token: caller}, attrs) do
    if AccessTokens.can_delegate?(
         caller,
         attrs.scopes,
         attrs.store_access_mode,
         attrs.store_ids
       ) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_org(%ApiPrincipal{type: :session}, _org, _scope), do: :ok

  defp authorize_org(%ApiPrincipal{type: :bearer, store_token: token}, org, scope) do
    case AccessTokens.authorize_org(token, org, scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp serialize_token(token) do
    %{
      id: token.id,
      name: token.name,
      store_name: legacy_store_name(token),
      store_access_mode: token.store_access_mode,
      stores: serialize_token_stores(token),
      scopes: token.scopes,
      permissions: serialize_permissions(token),
      expires_at: token.expires_at,
      last_used_at: token.last_used_at,
      inserted_at: token.inserted_at
    }
  end

  defp serialize_permissions(token) do
    %{
      read: AccessTokens.has_scope?(token, "entries:read"),
      write: AccessTokens.has_scope?(token, "entries:write")
    }
  end

  defp serialize_token_stores(%{store_access_mode: :all}), do: []

  defp serialize_token_stores(token) do
    token.store_grants
    |> Enum.map(fn grant ->
      %{id: grant.store.id, name: grant.store.name}
    end)
  end

  defp legacy_store_name(%{store_access_mode: :all}), do: "*"
  defp legacy_store_name(%{store: %{name: name}}), do: name
  defp legacy_store_name(token), do: token.store_ids |> Enum.join(",")

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
