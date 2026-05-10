defmodule DustWeb.Api.TokenApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.Stores
  alias DustWeb.Api.Refs

  action_fallback DustWeb.Api.FallbackController

  @token_ref Refs.schema("Token")
  @unauthorized Refs.unauthorized()
  @forbidden Refs.forbidden()
  @not_found Refs.not_found()
  @bad_request Refs.bad_request()
  @rate_limited Refs.rate_limited()

  operation :index,
    operation_id: "tokens.list",
    summary: "List API tokens for the current organization",
    tags: ["Tokens"],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{tokens: %{type: :array, items: @token_ref}},
           required: [:tokens]
         }, description: "List of tokens"},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      too_many_requests: @rate_limited
    ]

  def index(conn, _params) do
    org = conn.assigns.organization
    tokens = Stores.list_org_tokens(org)

    json(conn, %{tokens: Enum.map(tokens, &serialize_token/1)})
  end

  operation :create,
    operation_id: "tokens.create",
    summary: "Create a new API token",
    description:
      "The plaintext `raw_token` is returned **only on creation** — store it immediately. The server keeps a hashed copy and cannot recover it later.",
    tags: ["Tokens"],
    request_body:
      {%{
         type: :object,
         properties: %{
           store_name: %{type: :string, description: "Store the token will scope to."},
           name: %{type: :string, description: "Human-readable label for the token."},
           read: %{type: :boolean, default: true},
           write: %{type: :boolean, default: false}
         },
         required: [:store_name, :name],
         example: %{store_name: "config", name: "ci-deploy", read: true, write: true}
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
             store_name: %{type: :string},
             permissions: %{
               type: :object,
               properties: %{read: %{type: :boolean}, write: %{type: :boolean}},
               required: [:read, :write]
             }
           },
           required: [:id, :name, :raw_token, :store_name, :permissions]
         }, description: "Token created"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @not_found,
      unprocessable_entity:
        {Refs.schema("ValidationError"), description: "Validation error"},
      too_many_requests: @rate_limited
    ]

  def create(conn, %{"store_name" => store_name, "name" => name} = params) do
    org = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_write_permission(store_token),
         {:ok, store} <- find_store(org, store_name) do
      create_token(conn, store, store_token, store_name, name, params)
    end
  end

  def create(_conn, _params) do
    {:error, {:invalid_params, "store_name and name are required"}}
  end

  defp create_token(conn, store, store_token, store_name, name, params) do
    attrs = %{
      name: name,
      read: params["read"] != false,
      write: params["write"] == true,
      created_by_id: store_token.created_by_id
    }

    case Stores.create_store_token(store, attrs) do
      {:ok, token} ->
        conn
        |> put_status(201)
        |> json(%{
          id: token.id,
          name: token.name,
          raw_token: token.raw_token,
          store_name: store_name,
          permissions: %{
            read: Stores.StoreToken.can_read?(token),
            write: Stores.StoreToken.can_write?(token)
          }
        })

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: format_errors(changeset)})
    end
  end

  operation :delete,
    operation_id: "tokens.revoke",
    summary: "Revoke an API token",
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

  def delete(conn, %{"id" => id}) do
    store_token = conn.assigns.store_token
    org = conn.assigns.organization

    with :ok <- verify_write_permission(store_token),
         {:ok, _} <- Stores.revoke_token_in_org(id, org) do
      json(conn, %{ok: true})
    end
  end

  defp find_store(org, store_name) do
    case Stores.get_store_by_name(org, store_name) do
      nil -> {:error, :not_found}
      store -> {:ok, store}
    end
  end

  defp verify_write_permission(store_token) do
    if Stores.StoreToken.can_write?(store_token), do: :ok, else: {:error, :forbidden}
  end

  defp serialize_token(token) do
    %{
      id: token.id,
      name: token.name,
      store_name: token.store.name,
      permissions: %{
        read: Stores.StoreToken.can_read?(token),
        write: Stores.StoreToken.can_write?(token)
      },
      expires_at: token.expires_at,
      last_used_at: token.last_used_at,
      inserted_at: token.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
