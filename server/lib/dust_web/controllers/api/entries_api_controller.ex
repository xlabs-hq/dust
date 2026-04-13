defmodule DustWeb.Api.EntriesApiController do
  use DustWeb, :controller

  alias Dust.Stores
  alias Dust.Sync

  def index(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_read_permission(store_token),
         {:ok, pattern, opts} <- parse_opts(params),
         {:ok, page} <- Sync.enum_entries(store.id, pattern, opts) do
      json(conn, render_page(page))
    else
      {:error, :org_mismatch} ->
        conn |> put_status(404) |> json(%{"error" => "not_found"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{"error" => "not_found"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{"error" => "forbidden"})

      {:error, :invalid_pattern_for_prefixes} ->
        conn |> put_status(400) |> json(%{"error" => "invalid_pattern_for_prefixes"})

      {:error, {:invalid_params, detail}} ->
        conn |> put_status(400) |> json(%{"error" => "invalid_params", "detail" => detail})
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

  defp verify_read_permission(store_token) do
    if Stores.StoreToken.can_read?(store_token), do: :ok, else: {:error, :forbidden}
  end

  defp parse_opts(params) do
    with {:ok, pattern} <- parse_pattern(params),
         {:ok, limit} <- parse_limit(params),
         {:ok, order} <- parse_order(params),
         {:ok, select} <- parse_select(params),
         {:ok, after_cursor} <- parse_after(params) do
      opts =
        [limit: limit, order: order, select: select]
        |> maybe_put(:after, after_cursor)

      {:ok, pattern, opts}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_pattern(%{"pattern" => p}) when is_binary(p) and p != "", do: {:ok, p}

  defp parse_pattern(%{"pattern" => _}),
    do: {:error, {:invalid_params, "pattern must be a non-empty string"}}

  defp parse_pattern(_), do: {:ok, "**"}

  defp parse_limit(%{"limit" => l}) when is_binary(l) do
    case Integer.parse(l) do
      {n, ""} when n > 0 and n <= 1000 -> {:ok, n}
      _ -> {:error, {:invalid_params, "limit must be 1..1000"}}
    end
  end

  defp parse_limit(%{"limit" => _}), do: {:error, {:invalid_params, "limit must be 1..1000"}}
  defp parse_limit(_), do: {:ok, 50}

  defp parse_order(%{"order" => "asc"}), do: {:ok, :asc}
  defp parse_order(%{"order" => "desc"}), do: {:ok, :desc}

  defp parse_order(%{"order" => other}),
    do: {:error, {:invalid_params, "order=#{inspect(other)}"}}

  defp parse_order(_), do: {:ok, :asc}

  defp parse_select(%{"select" => "entries"}), do: {:ok, :entries}
  defp parse_select(%{"select" => "keys"}), do: {:ok, :keys}
  defp parse_select(%{"select" => "prefixes"}), do: {:ok, :prefixes}

  defp parse_select(%{"select" => other}),
    do: {:error, {:invalid_params, "select=#{inspect(other)}"}}

  defp parse_select(_), do: {:ok, :entries}

  defp parse_after(%{"after" => c}) when is_binary(c) and c != "", do: {:ok, c}
  defp parse_after(%{"after" => ""}), do: {:ok, nil}
  defp parse_after(%{"after" => _}), do: {:error, {:invalid_params, "after must be a string"}}
  defp parse_after(_), do: {:ok, nil}

  defp render_page(%{items: items, next_cursor: cursor}) do
    %{"items" => Enum.map(items, &render_item/1), "next_cursor" => cursor}
  end

  defp render_item(%{path: p, value: v, type: t, revision: r}) do
    %{"path" => p, "value" => v, "type" => t, "revision" => r}
  end

  defp render_item(path) when is_binary(path), do: path
end
