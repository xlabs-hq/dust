defmodule DustWeb.Api.WebhookController do
  use DustWeb, :controller

  alias Dust.{Stores, Webhooks}
  alias Dust.Webhooks.DeliveryWorker

  @ping_timeout 5_000

  def index(conn, %{"org" => org_slug, "store" => store_name}) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_read_permission(conn) do
      webhooks =
        Webhooks.list_webhooks(store)
        |> Enum.map(&serialize_webhook_without_secret/1)

      json(conn, %{webhooks: webhooks})
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def create(conn, %{"org" => org_slug, "store" => store_name} = params) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_write_permission(conn),
         {:ok, webhook} <- Webhooks.create_webhook(store, %{url: params["url"]}) do
      conn
      |> put_status(201)
      |> json(serialize_webhook_with_secret(webhook))
    else
      {:error, %Ecto.Changeset{} = _changeset} ->
        conn |> put_status(422) |> json(%{error: "invalid_params"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def delete(conn, %{"org" => org_slug, "store" => store_name, "id" => webhook_id}) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_write_permission(conn),
         :ok <- Webhooks.delete_webhook(webhook_id, store.id) do
      json(conn, %{ok: true})
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def ping(conn, %{"org" => org_slug, "store" => store_name, "id" => webhook_id}) do
    with :ok <- verify_org(conn, org_slug),
         {:ok, store} <- find_store(conn, store_name),
         :ok <- verify_token_scope(conn, store),
         :ok <- verify_write_permission(conn),
         {:ok, webhook} <- Webhooks.get_webhook(webhook_id, store.id) do
      payload =
        %{
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
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

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
    else
      {:error, reason} -> error_response(conn, reason)
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

  # --- Error responses ---

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val) and val > 0, do: val
  defp parse_int(_, default), do: default

  defp error_response(conn, :not_found),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp error_response(conn, :org_mismatch),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp error_response(conn, :forbidden),
    do: conn |> put_status(403) |> json(%{error: "forbidden"})
end
