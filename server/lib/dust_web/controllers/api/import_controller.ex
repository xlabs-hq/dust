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
           properties: %{
             ok: %{type: :boolean, description: "True iff every line either imported or was a header/blank."},
             imported: %{type: :integer, description: "Number of writes that returned :ok."},
             skipped: %{
               type: :integer,
               description: "Header rows + blank lines that were intentionally ignored."
             },
             unparseable: %{
               type: :integer,
               description: "Malformed JSON or rows missing a `path` field."
             },
             failed: %{
               type: :array,
               description: "Per-line failures. Empty when ok=true.",
               items: %{
                 type: :object,
                 properties: %{
                   line: %{type: :integer, description: "1-indexed source line number."},
                   path: %{type: ["string", "null"]},
                   reason: %{type: :string}
                 },
                 required: [:line, :reason]
               }
             }
           },
           required: [:ok, :imported, :skipped, :unparseable, :failed]
         }, description: "Import summary — `ok=true` and `failed=[]`."},
      multi_status:
        {%{
           type: :object,
           description:
             "Some lines failed. Same shape as 200; `ok=false` and `failed`/`unparseable` populated."
         }, description: "Partial success"},
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
      {:ok, summary} = Sync.Import.from_jsonl(store.id, lines, "system:import")

      response = %{
        ok: summary.failed == [] and summary.unparseable == 0,
        imported: summary.imported,
        skipped: summary.skipped,
        unparseable: summary.unparseable,
        failed: Enum.map(summary.failed, &serialize_failure/1)
      }

      status = if response.ok, do: 200, else: 207

      conn |> put_status(status) |> json(response)
    end
  end

  defp serialize_failure(%{line: line, path: path, reason: reason}) do
    %{line: line, path: path, reason: serialize_reason(reason)}
  end

  defp serialize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_reason({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp serialize_reason(reason), do: inspect(reason)

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
