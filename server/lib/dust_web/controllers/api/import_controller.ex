defmodule DustWeb.Api.ImportController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Stores, Sync}
  alias DustWeb.Api.Refs

  action_fallback DustWeb.Api.FallbackController

  operation :create,
    operation_id: "sync.import",
    summary: "Import JSONL into a store",
    description:
      "Each line is one entry's `{path, value, type}` — last write wins per path within the import. Existing entries are overwritten unconditionally; combine with `/diff` if you need pre-flight comparison.",
    tags: ["Sync"],
    parameters: [
      _: Refs.parameter("OrgSlug"),
      _: Refs.parameter("StoreName"),
      _: Refs.parameter("RequestId")
    ],
    request_body: [
      description: "Newline-delimited JSON entries.",
      required: true,
      content: %{
        "application/x-ndjson" => %{
          schema: %{type: :string, description: "Each line is one JSON entry."}
        }
      }
    ],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{ok: %{type: :boolean}, entries_imported: %{type: :integer}},
           required: [:ok, :entries_imported]
         }, description: "Import summary"},
      bad_request: Refs.bad_request(),
      unauthorized: Refs.unauthorized(),
      forbidden: Refs.forbidden(),
      not_found: Refs.not_found(),
      too_many_requests: Refs.rate_limited()
    ]

  def create(conn, %{"org" => org_slug, "store" => store_name}) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_write_permission(store_token),
         {:ok, body, conn} <- Plug.Conn.read_body(conn) do
      lines = String.split(body, "\n")
      {:ok, count} = Sync.Import.from_jsonl(store.id, lines, "system:import")
      json(conn, %{ok: true, entries_imported: count})
    end
  end

  defp verify_org(organization, org_slug) do
    if organization.slug == org_slug do
      :ok
    else
      {:error, :org_mismatch}
    end
  end

  defp find_store(organization, store_name) do
    case Stores.get_store_by_name(organization, store_name) do
      nil -> {:error, :not_found}
      store -> {:ok, store}
    end
  end

  defp verify_token_scope(store_token, store) do
    if store_token.store_id == store.id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp verify_write_permission(store_token) do
    if Stores.StoreToken.can_write?(store_token) do
      :ok
    else
      {:error, :forbidden}
    end
  end
end
