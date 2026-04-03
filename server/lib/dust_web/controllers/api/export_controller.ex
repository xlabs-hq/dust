defmodule DustWeb.Api.ExportController do
  use DustWeb, :controller

  alias Dust.{Stores, Sync}

  def show(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_read_permission(store_token) do
      format = Map.get(params, "format", "jsonl")
      do_export(conn, store, org_slug, store_name, format)
    else
      {:error, :org_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})
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

  defp verify_read_permission(store_token) do
    if Stores.StoreToken.can_read?(store_token) do
      :ok
    else
      {:error, :forbidden}
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
