defmodule DustWeb.Api.ExportController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Stores, Sync}
  alias DustWeb.Api.Refs
  alias DustWeb.ApiPrincipal

  action_fallback DustWeb.Api.FallbackController

  operation(:show,
    operation_id: "sync.export",
    summary: "Export a store as JSONL or SQLite",
    description:
      "`format=jsonl` (default) returns `application/x-ndjson` — one entry per line. `format=sqlite` returns a binary `.db` file (`application/x-sqlite3`) suitable for offline use.",
    tags: ["Sync"],
    parameters: [
      _: Refs.parameter("OrgSlug"),
      _: Refs.parameter("StoreName"),
      format: [
        in: :query,
        schema: %{type: :string, enum: ["jsonl", "sqlite"], default: "jsonl"},
        required: false
      ],
      _: Refs.parameter("RequestId")
    ],
    responses: [
      ok: [
        description: "Export payload",
        content: %{
          "application/x-ndjson" => %{
            schema: %{
              type: :string,
              description: "Newline-delimited JSON, one entry per line."
            }
          },
          "application/x-sqlite3" => %{
            schema: %{type: :string, format: :binary, description: "SQLite database file."}
          }
        }
      ],
      unauthorized: Refs.unauthorized(),
      forbidden: Refs.forbidden(),
      not_found: Refs.not_found(),
      too_many_requests: Refs.rate_limited()
    ]
  )

  def show(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    principal = conn.assigns.api_principal

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- authorize_store(principal, store, "entries:read") do
      format = Map.get(params, "format", "jsonl")
      do_export(conn, store, org_slug, store_name, format)
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

  defp authorize_store(principal, store, scope) do
    case ApiPrincipal.authorize_store(principal, store, scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp do_export(conn, store, org_slug, store_name, "sqlite") do
    filename = "#{org_slug}_#{store_name}"
    tmp_path = Path.join(System.tmp_dir!(), "export_#{System.unique_integer([:positive])}.db")

    case Sync.Export.to_sqlite_file(store.id, tmp_path) do
      :ok ->
        conn =
          conn
          |> put_resp_content_type("application/x-sqlite3")
          |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}.db\"")
          |> send_file(200, tmp_path)

        File.rm(tmp_path)
        conn

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "export_failed"})
    end
  end

  defp do_export(conn, store, org_slug, store_name, _format) do
    full_name = "#{org_slug}/#{store_name}"
    lines = Sync.Export.to_jsonl_lines(store.id, full_name)
    body = Enum.join(lines, "\n") <> "\n"

    conn
    |> put_resp_content_type("application/x-ndjson")
    |> send_resp(200, body)
  end
end
