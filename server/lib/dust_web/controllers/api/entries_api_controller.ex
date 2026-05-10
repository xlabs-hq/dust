defmodule DustWeb.Api.EntriesApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.Stores
  alias Dust.Sync

  action_fallback DustWeb.Api.FallbackController

  @entry_schema %{
    type: :object,
    properties: %{
      path: %{type: :string},
      value: %{description: "Entry value (any JSON type)"},
      type: %{type: :string, enum: ["string", "integer", "float", "boolean", "map", "list", "decimal", "datetime", "file"]},
      revision: %{type: :integer, description: "Per-entry sequence number"}
    }
  }

  @org_store_params [
    org: [in: :path, schema: %{type: :string}, required: true],
    store: [in: :path, schema: %{type: :string}, required: true]
  ]

  operation :show,
    summary: "Read a single entry by path",
    tags: ["Entries"],
    parameters:
      @org_store_params ++
        [
          path: [
            in: :path,
            schema: %{type: :string},
            required: true,
            description: "Dot-separated path"
          ]
        ],
    responses: [
      ok: {@entry_schema, description: "Entry"},
      not_found:
        {%{type: :object, properties: %{error: %{type: :string}}}, description: "No such entry"}
    ]

  def show(conn, %{"org" => org_slug, "store" => store_name, "path" => path_segments}) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token
    path = Enum.join(List.wrap(path_segments), ".")

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_read_permission(store_token),
         {:ok, entry} <- fetch_entry(store.id, path) do
      json(conn, render_entry(entry))
    end
  end

  defp fetch_entry(store_id, path) do
    case Sync.get_entry(store_id, path) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp render_entry(%{path: p, value: v, type: t, seq: s}) do
    %{path: p, value: v, type: t, revision: s}
  end

  operation :index,
    summary: "List entries by glob pattern or key range",
    description:
      "Use `pattern` for glob matching (default `**`), or `from`+`to` for a key range. The two modes are mutually exclusive.",
    tags: ["Entries"],
    parameters:
      @org_store_params ++
        [
          pattern: [in: :query, schema: %{type: :string, default: "**"}, required: false],
          from: [
            in: :query,
            schema: %{type: :string},
            required: false,
            description: "Range start (inclusive)"
          ],
          to: [
            in: :query,
            schema: %{type: :string},
            required: false,
            description: "Range end (exclusive)"
          ],
          limit: [
            in: :query,
            schema: %{type: :integer, default: 50, maximum: 1000},
            required: false
          ],
          order: [
            in: :query,
            schema: %{type: :string, enum: ["asc", "desc"], default: "asc"},
            required: false
          ],
          select: [
            in: :query,
            schema: %{type: :string, enum: ["entries", "keys", "prefixes"], default: "entries"},
            required: false
          ],
          after: [
            in: :query,
            schema: %{type: :string},
            required: false,
            description: "Pagination cursor"
          ]
        ],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             items: %{
               oneOf: [
                 %{type: :array, items: @entry_schema},
                 %{type: :array, items: %{type: :string}}
               ]
             },
             next_cursor: %{type: :string, nullable: true}
           }
         }, description: "Page of entries (or keys/prefixes)"}
    ]

  def index(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with :ok <- validate_mutually_exclusive(params),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_read_permission(store_token) do
      case dispatch_mode(params) do
        :range -> do_range(conn, store, params)
        :enum -> do_enum(conn, store, params)
      end
    end
  end

  operation :put,
    summary: "Write an entry at the given path",
    description:
      "Set the value at `path`. Pass `If-Match: <revision>` for compare-and-swap (CAS) writes. Body can be any JSON value.",
    tags: ["Entries"],
    parameters:
      @org_store_params ++
        [
          path: [in: :path, schema: %{type: :string}, required: true]
        ],
    request_body:
      {%{description: "Any JSON value (object, scalar, array)"}, description: "Entry value"},
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             revision: %{type: :integer},
             store_seq: %{type: :integer}
           }
         }, description: "Write accepted"},
      bad_request:
        {%{
           type: :object,
           properties: %{error: %{type: :string}, detail: %{type: :string}}
         }, description: "Invalid request"},
      precondition_failed:
        {%{
           type: :object,
           properties: %{
             error: %{type: :string, enum: ["conflict"]},
             current_revision: %{type: :integer, nullable: true}
           }
         }, description: "If-Match revision mismatch"}
    ]

  def put(conn, %{"org" => org_slug, "store" => store_name, "path" => path_segments}) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token
    path = Enum.join(List.wrap(path_segments), ".")

    with {:ok, value} <- extract_put_value(conn),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_write_permission(store_token),
         {:ok, attrs} <- build_put_attrs(conn, path, value, store_token) do
      write_and_respond(conn, store, path, attrs)
    end
  end

  defp write_and_respond(conn, store, path, attrs) do
    case Sync.write(store.id, attrs) do
      {:ok, op} ->
        json(conn, %{revision: op.store_seq, store_seq: op.store_seq})

      {:error, :conflict} ->
        conn
        |> put_status(412)
        |> json(%{
          error: "conflict",
          current_revision: current_revision_for(store, path)
        })

      {:error, :if_match_unsupported_op} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "if_match_unsupported_op",
          detail: "If-Match is only supported for set operations"
        })

      {:error, :if_match_multi_leaf} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "if_match_multi_leaf",
          detail: "If-Match requires a leaf value, not a map/dict"
        })

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_params", detail: inspect(reason)})
    end
  end

  defp extract_put_value(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:error, {:invalid_params, "request body could not be parsed"}}

      %{"_json" => value} ->
        {:ok, value}

      map when is_map(map) and map_size(map) == 0 ->
        {:error, {:invalid_params, "request body is empty"}}

      map when is_map(map) ->
        {:ok, map}
    end
  end

  defp build_put_attrs(conn, path, value, store_token) do
    base = %{
      op: :set,
      path: path,
      value: value,
      device_id: "http:" <> to_string(store_token.id),
      client_op_id: request_op_id(conn)
    }

    case get_req_header(conn, "if-match") do
      [] ->
        {:ok, base}

      [raw | _] ->
        case Integer.parse(raw) do
          {n, ""} when n > 0 -> {:ok, Map.put(base, :if_match, n)}
          _ -> {:error, {:invalid_params, "If-Match must be a positive integer"}}
        end
    end
  end

  defp request_op_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [id | _] when is_binary(id) and id != "" -> id
      _ -> Ecto.UUID.generate()
    end
  end

  defp current_revision_for(store, path) do
    case Sync.get_entry(store.id, path) do
      %{seq: seq} -> seq
      _ -> nil
    end
  end

  defp verify_write_permission(store_token) do
    if Stores.StoreToken.can_write?(store_token), do: :ok, else: {:error, :forbidden}
  end

  operation :batch,
    summary: "Read multiple entries in one request",
    tags: ["Entries"],
    parameters: @org_store_params,
    request_body:
      {%{
         type: :object,
         properties: %{
           paths: %{
             type: :array,
             items: %{type: :string},
             maxItems: 1000,
             description: "Up to 1000 entry paths"
           }
         },
         required: [:paths]
       }, description: "Batch read request"},
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             entries: %{
               type: :object,
               additionalProperties: @entry_schema,
               description: "Map keyed by path"
             },
             missing: %{type: :array, items: %{type: :string}}
           }
         }, description: "Batch result"}
    ]

  def batch(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    store_token = conn.assigns.store_token

    with {:ok, paths} <- parse_batch_paths(params),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_token_scope(store_token, store),
         :ok <- verify_read_permission(store_token) do
      %{entries: entries, missing: missing} = Sync.get_many_entries(store.id, paths)

      json(conn, %{
        entries: render_batch_entries(entries),
        missing: missing
      })
    end
  end

  defp parse_batch_paths(%{"paths" => paths}) when is_list(paths) do
    cond do
      length(paths) > 1000 ->
        {:error, {:invalid_params, "maximum 1000 paths per batch"}}

      not Enum.all?(paths, &is_binary/1) ->
        {:error, {:invalid_params, "paths must be strings"}}

      true ->
        {:ok, paths}
    end
  end

  defp parse_batch_paths(_), do: {:error, {:invalid_params, "paths required"}}

  defp render_batch_entries(entries) do
    Map.new(entries, fn {path, %{value: v, type: t, seq: s}} ->
      {path, %{value: v, type: t, revision: s}}
    end)
  end

  defp validate_mutually_exclusive(params) do
    cond do
      Map.has_key?(params, "pattern") and
          (Map.has_key?(params, "from") or Map.has_key?(params, "to")) ->
        {:error, {:conflicting_params, "use either pattern or from/to, not both"}}

      Map.has_key?(params, "from") and not Map.has_key?(params, "to") ->
        {:error, {:invalid_params, "from requires to"}}

      Map.has_key?(params, "to") and not Map.has_key?(params, "from") ->
        {:error, {:invalid_params, "to requires from"}}

      true ->
        :ok
    end
  end

  defp dispatch_mode(params) do
    if Map.has_key?(params, "from"), do: :range, else: :enum
  end

  defp do_enum(conn, store, params) do
    with {:ok, pattern, opts} <- parse_opts(params),
         {:ok, page} <- Sync.enum_entries(store.id, pattern, opts) do
      json(conn, render_page(page))
    else
      {:error, :invalid_pattern_for_prefixes} ->
        conn |> put_status(400) |> json(%{error: "invalid_pattern_for_prefixes"})

      {:error, {:invalid_params, detail}} ->
        conn |> put_status(400) |> json(%{error: "invalid_params", detail: detail})
    end
  end

  defp do_range(conn, store, params) do
    with {:ok, from, to, opts} <- parse_range_opts(params),
         {:ok, page} <- Sync.range_entries(store.id, from, to, opts) do
      json(conn, render_page(page))
    else
      {:error, :unsupported_select} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "unsupported_select",
          detail: "select=prefixes not supported for range"
        })

      {:error, {:invalid_params, detail}} ->
        conn |> put_status(400) |> json(%{error: "invalid_params", detail: detail})
    end
  end

  defp parse_range_opts(params) do
    with {:ok, from} <- parse_from(params),
         {:ok, to} <- parse_to(params),
         {:ok, limit} <- parse_limit(params),
         {:ok, order} <- parse_order(params),
         {:ok, select} <- parse_select(params),
         {:ok, after_cursor} <- parse_after(params) do
      opts =
        [limit: limit, order: order, select: select]
        |> maybe_put(:after, after_cursor)

      {:ok, from, to, opts}
    end
  end

  defp parse_from(%{"from" => f}) when is_binary(f) and f != "", do: {:ok, f}
  defp parse_from(_), do: {:error, {:invalid_params, "from must be a non-empty string"}}

  defp parse_to(%{"to" => t}) when is_binary(t) and t != "", do: {:ok, t}
  defp parse_to(_), do: {:error, {:invalid_params, "to must be a non-empty string"}}

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
    %{items: Enum.map(items, &render_item/1), next_cursor: cursor}
  end

  defp render_item(%{path: p, value: v, type: t, revision: r}) do
    %{path: p, value: v, type: t, revision: r}
  end

  defp render_item(path) when is_binary(path), do: path
end
