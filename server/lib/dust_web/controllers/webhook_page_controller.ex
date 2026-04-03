defmodule DustWeb.WebhookPageController do
  use DustWeb, :controller

  alias Dust.{Stores, Webhooks}

  def index(conn, %{"name" => store_name}) do
    scope = conn.assigns.current_scope
    store = Stores.get_store_by_org_and_name!(scope.organization, store_name)
    webhooks = Webhooks.list_webhooks(store)

    webhooks_with_deliveries =
      Enum.map(webhooks, fn wh ->
        deliveries = Webhooks.list_deliveries(wh.id, limit: 10)
        serialize_webhook(wh, deliveries)
      end)

    conn
    |> assign(:page_title, "Webhooks — #{store.name}")
    |> render_inertia("Stores/Webhooks", %{
      store: %{
        id: store.id,
        name: store.name,
        full_name: "#{scope.organization.slug}/#{store.name}"
      },
      webhooks: webhooks_with_deliveries
    })
  end

  def create(conn, %{"name" => store_name, "url" => url}) do
    scope = conn.assigns.current_scope
    store = Stores.get_store_by_org_and_name!(scope.organization, store_name)

    case Webhooks.create_webhook(store, %{url: url}) do
      {:ok, webhook} ->
        conn
        |> put_flash(:info, "Webhook created. Secret: #{webhook.secret}")
        |> redirect(to: "/#{scope.organization.slug}/stores/#{store.name}/webhooks")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Invalid webhook URL. Must start with http:// or https://")
        |> redirect(to: "/#{scope.organization.slug}/stores/#{store.name}/webhooks")
    end
  end

  def delete(conn, %{"name" => store_name, "id" => webhook_id}) do
    scope = conn.assigns.current_scope
    store = Stores.get_store_by_org_and_name!(scope.organization, store_name)
    Webhooks.delete_webhook(webhook_id, store.id)

    conn
    |> put_flash(:info, "Webhook deleted")
    |> redirect(to: "/#{scope.organization.slug}/stores/#{store.name}/webhooks")
  end

  defp serialize_webhook(webhook, deliveries) do
    %{
      id: webhook.id,
      url: webhook.url,
      active: webhook.active,
      last_delivered_seq: webhook.last_delivered_seq,
      failure_count: webhook.failure_count,
      created_at: webhook.inserted_at,
      deliveries:
        Enum.map(deliveries, fn d ->
          %{
            store_seq: d.store_seq,
            status_code: d.status_code,
            response_ms: d.response_ms,
            error: d.error,
            attempted_at: d.attempted_at
          }
        end)
    }
  end
end
