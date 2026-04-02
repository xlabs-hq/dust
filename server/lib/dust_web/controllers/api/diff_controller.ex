defmodule DustWeb.Api.DiffController do
  use DustWeb, :controller

  alias Dust.{Stores, Sync}

  def show(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         {:ok, from_seq} <- parse_int(params, "from_seq"),
         to_seq <- parse_optional_int(params, "to_seq"),
         {:ok, diff} <- Sync.Diff.changes(store.id, from_seq, to_seq) do
      json(conn, %{
        from_seq: diff.from_seq,
        to_seq: diff.to_seq,
        changes:
          Enum.map(diff.changes, fn c ->
            %{path: c.path, before: c.before, after: c.after}
          end)
      })
    else
      {:error, :org_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :invalid_param, field} ->
        conn |> put_status(400) |> json(%{error: "invalid_param", field: field})

      {:error, :compacted, %{earliest_available: earliest}} ->
        conn |> put_status(409) |> json(%{error: "compacted", earliest_available: earliest})
    end
  end

  defp verify_org(organization, org_slug) do
    if organization.slug == org_slug, do: :ok, else: {:error, :org_mismatch}
  end

  defp find_store(organization, store_name) do
    case Stores.get_store_by_name(organization, store_name) do
      nil -> {:error, :not_found}
      store -> {:ok, store}
    end
  end

  defp verify_token_scope(store_token, store) do
    if store_token.store_id == store.id, do: :ok, else: {:error, :forbidden}
  end

  defp parse_int(params, key) do
    case Map.get(params, key) do
      nil -> {:error, :invalid_param, key}
      val when is_binary(val) -> parse_int_string(val, key)
      val when is_integer(val) -> {:ok, val}
      _ -> {:error, :invalid_param, key}
    end
  end

  defp parse_int_string(val, key) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_param, key}
    end
  end

  defp parse_optional_int(params, key) do
    case Map.get(params, key) do
      nil -> nil
      val when is_binary(val) ->
        case Integer.parse(val) do
          {int, ""} -> int
          _ -> nil
        end
      val when is_integer(val) -> val
      _ -> nil
    end
  end
end
