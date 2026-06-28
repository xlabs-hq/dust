defmodule DustWeb.Api.ImportController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Stores, Sync}
  alias DustWeb.Api.Refs
  alias DustWeb.ApiPrincipal

  action_fallback DustWeb.Api.FallbackController

  operation(:create,
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
           description: """
           Import was processed. Inspect the response body to learn
           the outcome of each line — partial success is signalled by
           `ok: false` with non-empty `failed` and/or non-zero
           `unparseable`, **not** by the status code. Writes are not
           transactional: any line that imported is permanent
           regardless of whether later lines fail.
           """,
           properties: %{
             ok: %{
               type: :boolean,
               description:
                 "`true` iff every line either imported or was an intentionally-ignored header/blank."
             },
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
               description: "Per-line failures. Empty when `ok=true`.",
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
         }, description: "Import processed (may be partial — see body)"},
      bad_request: Refs.bad_request(),
      unauthorized: Refs.unauthorized(),
      forbidden: Refs.forbidden(),
      not_found: Refs.not_found(),
      too_many_requests: Refs.rate_limited()
    ]
  )

  def create(conn, %{"org" => org_slug, "store" => store_name}) do
    organization = conn.assigns.organization
    principal = conn.assigns.api_principal

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- authorize_store(principal, store, "entries:write"),
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

      # Partial-success-of-included-items is a body concern, not a
      # status concern. The request was accepted and processed; the
      # body describes per-line outcomes. Consumers should always
      # check `ok` and `failed` regardless of status code.
      json(conn, response)
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

  defp authorize_store(principal, store, scope) do
    case ApiPrincipal.authorize_store(principal, store, scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end
end
