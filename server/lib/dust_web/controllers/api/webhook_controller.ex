defmodule DustWeb.Api.WebhookController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Stores, Webhooks}
  alias Dust.Webhooks.DeliveryWorker

  action_fallback DustWeb.Api.FallbackController

  @ping_timeout 5_000

  @webhook_schema %{
    type: :object,
    properties: %{
      id: %{type: :string, format: :uuid},
      url: %{type: :string, format: :uri},
      active: %{type: :boolean},
      failure_count: %{type: :integer},
      last_delivered_seq: %{type: :integer, nullable: true},
      inserted_at: %{type: :string, format: "date-time"}
    }
  }

  @org_store_params [
    org: [in: :path, schema: %{type: :string}, required: true],
    store: [in: :path, schema: %{type: :string}, required: true]
  ]

  operation :index,
    summary: "List webhooks for a store",
    tags: ["Webhooks"],
    parameters: @org_store_params,
    responses: [
      ok:
        {%{type: :object, properties: %{webhooks: %{type: :array, items: @webhook_schema}}},
         description: "List of webhooks"}
    ]

  def index(conn, %{"org" => org_slug, "store" => store_name}) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_read_permission(conn) do
      webhooks =
        Webhooks.list_webhooks(store)
        |> Enum.map(&serialize_webhook_without_secret/1)

      json(conn, %{webhooks: webhooks})
    end
  end

  operation :create,
    summary: "Register a new webhook",
    tags: ["Webhooks"],
    parameters: @org_store_params,
    request_body:
      {%{
         type: :object,
         properties: %{url: %{type: :string, format: :uri}},
         required: [:url]
       }, description: "Webhook URL"},
    responses: [
      created:
        {%{
           type: :object,
           properties: %{
             id: %{type: :string, format: :uuid},
             url: %{type: :string},
             secret: %{type: :string, description: "HMAC signing secret. Only returned on create."},
             active: %{type: :boolean},
             inserted_at: %{type: :string, format: "date-time"}
           }
         }, description: "Webhook created"},
      unprocessable_entity:
        {%{type: :object, properties: %{error: %{type: :string}}}, description: "Invalid params"}
    ]

  def create(conn, %{"org" => org_slug, "store" => store_name} = params) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_write_permission(conn) do
      do_create_webhook(conn, store, params)
    end
  end

  defp do_create_webhook(conn, store, params) do
    case Webhooks.create_webhook(store, %{url: params["url"]}) do
      {:ok, webhook} ->
        conn
        |> put_status(201)
        |> json(serialize_webhook_with_secret(webhook))

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{error: "invalid_params"})
    end
  end

  operation :delete,
    summary: "Delete a webhook",
    tags: ["Webhooks"],
    parameters:
      @org_store_params ++
        [id: [in: :path, schema: %{type: :string, format: :uuid}, required: true]],
    responses: [
      ok: {%{type: :object, properties: %{ok: %{type: :boolean}}}, description: "Webhook deleted"}
    ]

  def delete(conn, %{"org" => org_slug, "store" => store_name, "id" => webhook_id}) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_write_permission(conn),
         :ok <- Webhooks.delete_webhook(webhook_id, store.id) do
      json(conn, %{ok: true})
    end
  end

  operation :ping,
    summary: "Send a test ping to a webhook",
    tags: ["Webhooks"],
    parameters:
      @org_store_params ++
        [id: [in: :path, schema: %{type: :string, format: :uuid}, required: true]],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             ok: %{type: :boolean},
             status_code: %{type: :integer},
             response_ms: %{type: :integer}
           }
         }, description: "Ping result"},
      bad_gateway:
        {%{type: :object, properties: %{ok: %{type: :boolean}, error: %{type: :string}}},
         description: "Webhook endpoint unreachable"}
    ]

  def ping(conn, %{"org" => org_slug, "store" => store_name, "id" => webhook_id}) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_write_permission(conn),
         {:ok, webhook} <- Webhooks.get_webhook(webhook_id, store.id) do
      do_ping(conn, webhook, org_slug, store_name)
    end
  end

  defp do_ping(conn, webhook, org_slug, store_name) do
    payload = %{
      event: "ping",
      store: "#{org_slug}/#{store_name}",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    body = Jason.encode!(payload)
    signature = DeliveryWorker.sign(body, webhook.secret)
    start_time = System.monotonic_time(:millisecond)

    case Req.post(webhook.url,
           body: body,
           headers: [
             {"content-type", "application/json"},
             {"x-dust-signature", "sha256=#{signature}"}
           ],
           receive_timeout: @ping_timeout,
           retry: false
         ) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        Webhooks.reactivate(webhook.id)
        json(conn, %{ok: true, status_code: status, response_ms: elapsed})

      {:ok, %{status: status}} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        json(conn, %{ok: false, status_code: status, response_ms: elapsed})

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(%{ok: false, error: inspect(reason)})
    end
  end

  operation :deliveries,
    summary: "List recent webhook delivery attempts",
    tags: ["Webhooks"],
    parameters:
      @org_store_params ++
        [
          id: [in: :path, schema: %{type: :string, format: :uuid}, required: true],
          limit: [
            in: :query,
            schema: %{type: :integer, default: 20, maximum: 100},
            required: false
          ]
        ],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             deliveries: %{
               type: :array,
               items: %{
                 type: :object,
                 properties: %{
                   id: %{type: :string, format: :uuid},
                   store_seq: %{type: :integer},
                   status_code: %{type: :integer, nullable: true},
                   response_ms: %{type: :integer, nullable: true},
                   error: %{type: :string, nullable: true},
                   attempted_at: %{type: :string, format: "date-time"}
                 }
               }
             }
           }
         }, description: "Recent deliveries"}
    ]

  def deliveries(conn, %{"org" => org_slug, "store" => store_name, "id" => webhook_id} = params) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_read_permission(conn),
         {:ok, _webhook} <- Webhooks.get_webhook(webhook_id, store.id) do
      limit = min(parse_int(params["limit"], 20), 100)

      deliveries =
        Webhooks.list_deliveries(webhook_id, limit: limit)
        |> Enum.map(&serialize_delivery/1)

      json(conn, %{deliveries: deliveries})
    end
  end

  # --- Auth helpers ---

  defp verify_org(conn, org_slug) do
    if conn.assigns.organization.slug == org_slug do
      :ok
    else
      {:error, :org_mismatch}
    end
  end

  defp find_store(conn, store_name) do
    case Stores.get_store_by_name(conn.assigns.organization, store_name) do
      nil -> {:error, :not_found}
      store -> {:ok, store}
    end
  end

  defp verify_token_scope(conn, store) do
    if conn.assigns.store_token.store_id == store.id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp verify_read_permission(conn) do
    if Stores.StoreToken.can_read?(conn.assigns.store_token) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp verify_write_permission(conn) do
    if Stores.StoreToken.can_write?(conn.assigns.store_token) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  # --- Serialization ---

  defp serialize_webhook_without_secret(webhook) do
    %{
      id: webhook.id,
      url: webhook.url,
      active: webhook.active,
      failure_count: webhook.failure_count,
      last_delivered_seq: webhook.last_delivered_seq,
      inserted_at: webhook.inserted_at
    }
  end

  defp serialize_webhook_with_secret(webhook) do
    %{
      id: webhook.id,
      url: webhook.url,
      secret: webhook.secret,
      active: webhook.active,
      inserted_at: webhook.inserted_at
    }
  end

  defp serialize_delivery(delivery) do
    %{
      id: delivery.id,
      store_seq: delivery.store_seq,
      status_code: delivery.status_code,
      response_ms: delivery.response_ms,
      error: delivery.error,
      attempted_at: delivery.attempted_at
    }
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val) and val > 0, do: val
  defp parse_int(_, default), do: default
end
