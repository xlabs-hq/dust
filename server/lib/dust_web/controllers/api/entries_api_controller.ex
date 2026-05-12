defmodule DustWeb.Api.EntriesApiController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.Stores
  alias Dust.Sync
  alias DustWeb.ApiPrincipal
  alias DustWeb.Api.Refs

  action_fallback DustWeb.Api.FallbackController

  @entry_ref Refs.schema("Entry")
  @unauthorized Refs.unauthorized()
  @forbidden Refs.forbidden()
  @not_found Refs.not_found()
  @bad_request Refs.bad_request()
  @rate_limited Refs.rate_limited()

  @write_ack_schema %{
    type: :object,
    properties: %{
      revision: %{type: :integer, description: "Per-entry sequence after the write."},
      store_seq: %{
        type: :integer,
        description: "Store-wide monotonic sequence after the write."
      }
    },
    required: [:revision, :store_seq],
    example: %{revision: 8, store_seq: 142}
  }

  @conflict_schema %{
    type: :object,
    properties: %{
      error: %{type: :string, enum: ["conflict"]},
      current_revision: %{type: ["integer", "null"]}
    },
    required: [:error]
  }

  # Parameter refs use the `_` key per oaskit convention — the actual
  # name comes from the component definition. Keyword lists can have
  # duplicate keys, so multiple `_:` entries are fine.
  @org_store_params [
    _: Refs.parameter("OrgSlug"),
    _: Refs.parameter("StoreName")
  ]

  @entry_path_param [_: Refs.parameter("EntryPath")]
  @if_match_param [_: Refs.parameter("IfMatch")]
  @request_id_param [_: Refs.parameter("RequestId")]

  operation :show,
    operation_id: "entries.get",
    summary: "Read a single entry by path (or probe existence with HEAD)",
    description: """
    `GET` returns the entry value, type, and revision. `HEAD` is the
    cheap S3-style existence probe — same headers (including `ETag`),
    no body. Returns 200 if the path resolves to a leaf entry or any
    descendant under a subtree; 404 otherwise.

    `ETag` carries the entry's current `revision` — for leaf paths
    this is the entry's seq, for subtree paths it is the max seq
    across descendants.
    """,
    tags: ["Entries"],
    parameters: @org_store_params ++ @entry_path_param ++ @request_id_param,
    responses: [
      ok: {@entry_ref, description: "Entry (HEAD: same headers, no body)"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      not_found: @not_found,
      too_many_requests: @rate_limited
    ]

  def show(conn, %{"org" => org_slug, "store" => store_name, "path" => path_segments}) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with {:ok, path} <- url_path(path_segments),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_read(principal),
         {:ok, entry} <- fetch_entry(store.id, path) do
      conn
      |> put_resp_header("etag", ~s("#{entry.seq}"))
      |> json(render_entry(entry))
    end
  end

  defp url_path(segments) do
    case DustProtocol.Path.LegacyDot.from_url_segments(List.wrap(segments)) do
      {:ok, path} ->
        {:ok, path}

      {:error, :dot_in_segment} ->
        {:error,
         {:invalid_params,
          "URL path segments cannot contain '.' — use slashes between levels (e.g. /entries/foo/bar/baz)"}}

      {:error, :empty_segment} ->
        {:error, {:invalid_params, "path cannot contain empty segments"}}

      {:error, :empty_path} ->
        {:error, {:invalid_params, "path is required"}}
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
    operation_id: "entries.list",
    summary: "List entries by glob pattern or key range",
    description: """
    Use `pattern` for glob matching (default `**`), or `from`+`to` for
    a lexicographic key range. The two modes are mutually exclusive.

    `*` matches a single path segment. `**` matches one or more
    segments. Slashes between segments are accepted as aliases for
    dots — so `pattern=projects/alpha/*` is equivalent to
    `pattern=projects.alpha.*`.

    Use `select=keys` to return path strings only, or `select=prefixes`
    (pattern mode only) to return distinct next-segment prefixes
    matching `<base>.**`.
    """,
    tags: ["Entries"],
    parameters:
      @org_store_params ++
        [
          pattern: [
            in: :query,
            schema: %{type: :string, default: "**", example: "projects/alpha/*"},
            required: false,
            description: "Glob pattern. Mutually exclusive with `from`/`to`."
          ],
          from: [
            in: :query,
            schema: %{type: :string},
            required: false,
            description: "Range start (inclusive). Requires `to`."
          ],
          to: [
            in: :query,
            schema: %{type: :string},
            required: false,
            description: "Range end (exclusive). Requires `from`."
          ],
          limit: [
            in: :query,
            schema: %{type: :integer, default: 50, maximum: 1000, minimum: 1},
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
            description: "Opaque pagination cursor — pass the previous response's `next_cursor`."
          ]
        ] ++ @request_id_param,
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             items: %{
               oneOf: [
                 %{type: :array, items: @entry_ref},
                 %{type: :array, items: %{type: :string}}
               ],
               description:
                 "Array of entries (default), keys (`select=keys`), or prefix strings (`select=prefixes`)."
             },
             next_cursor: %{type: ["string", "null"]}
           },
           required: [:items, :next_cursor]
         }, description: "Page of entries (or keys/prefixes)"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      too_many_requests: @rate_limited
    ]

  def index(conn, %{"org" => org_slug, "store" => store_name} = params) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with :ok <- validate_mutually_exclusive(params),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_read(principal) do
      case dispatch_mode(params) do
        :range -> do_range(conn, store, params)
        :enum -> do_enum(conn, store, params)
      end
    end
  end

  operation :put,
    operation_id: "entries.put",
    summary: "Write an entry at the given path",
    description: """
    Set the value at `path`. The body can be any JSON value (object,
    scalar, array, or `null`). Note that `null` is stored as a
    *value* — the entry remains in the store with `value: null`. To
    actually remove an entry, use `DELETE /entries/{path}`.

    To perform a compare-and-swap write, send the `If-Match` header
    with the entry's current `revision` — the write fails with `412`
    if the revision has advanced. CAS is leaf-only (no subtree CAS).

    Optionally send `X-Request-Id` to attach an opaque correlation
    id; if present, it is used as the write's `client_op_id` for
    server-side deduplication.
    """,
    tags: ["Entries"],
    parameters:
      @org_store_params ++ @entry_path_param ++ @if_match_param ++ @request_id_param,
    request_body:
      {%{description: "Any JSON value (object, scalar, array, string, number, boolean, null)"},
       description: "Entry value"},
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             revision: %{type: :integer, description: "Per-entry sequence after the write."},
             store_seq: %{
               type: :integer,
               description: "Store-wide monotonic sequence after the write."
             }
           },
           required: [:revision, :store_seq],
           example: %{revision: 8, store_seq: 142}
         }, description: "Write accepted"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      precondition_failed:
        {%{
           type: :object,
           properties: %{
             error: %{type: :string, enum: ["conflict"]},
             current_revision: %{type: ["integer", "null"]}
           },
           required: [:error]
         }, description: "If-Match revision mismatch"},
      too_many_requests: @rate_limited
    ]

  def put(conn, %{"org" => org_slug, "store" => store_name, "path" => path_segments}) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with {:ok, path} <- url_path(path_segments),
         {:ok, value} <- extract_put_value(conn),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_write(principal),
         {:ok, attrs} <- build_put_attrs(conn, path, value, principal) do
      write_and_respond(conn, store, path, attrs)
    end
  end

  operation :delete,
    operation_id: "entries.delete",
    summary: "Delete an entry (or subtree) at the given path",
    description: """
    Removes the entry at `path`. If `path` is a subtree (interior node),
    every descendant entry is removed as well. The op is appended to the
    log even if no entries existed — DELETE is idempotent.

    To perform a compare-and-swap delete on a leaf, send the `If-Match`
    header with the entry's current `revision` — the delete fails with
    `412` if the revision has advanced. CAS is leaf-only; If-Match
    against a subtree path will never match and returns 412.
    """,
    tags: ["Entries"],
    parameters:
      @org_store_params ++ @entry_path_param ++ @if_match_param ++ @request_id_param,
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             revision: %{
               type: :integer,
               description: "Per-entry sequence after the delete (== store_seq)."
             },
             store_seq: %{
               type: :integer,
               description: "Store-wide monotonic sequence after the delete."
             }
           },
           required: [:revision, :store_seq],
           example: %{revision: 9, store_seq: 143}
         }, description: "Delete accepted"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      precondition_failed:
        {%{
           type: :object,
           properties: %{
             error: %{type: :string, enum: ["conflict"]},
             current_revision: %{type: ["integer", "null"]}
           },
           required: [:error]
         }, description: "If-Match revision mismatch"},
      too_many_requests: @rate_limited
    ]

  def delete(conn, %{"org" => org_slug, "store" => store_name, "path" => path_segments}) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with {:ok, path} <- url_path(path_segments),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_write(principal),
         {:ok, attrs} <- build_delete_attrs(conn, path, principal) do
      write_and_respond(conn, store, path, attrs)
    end
  end

  # --- Body-path variants (UI-friendly: path in body, not URL) -------

  operation :create,
    operation_id: "entries.create",
    summary: "Upsert an entry with the path in the request body",
    description: """
    Same semantics as `PUT /entries/{path}`, but the path travels in
    the request body. Designed for the web UI: avoids slash-encoding
    dotted paths and lets the writer carry `if_match` in the body
    rather than a header.

    Body: `{"path": "links.foo.title", "value": <any JSON>, "if_match"?: <int>}`.
    """,
    tags: ["Entries"],
    parameters: @org_store_params ++ @request_id_param,
    request_body:
      {%{
         type: :object,
         properties: %{
           path: %{type: :string, example: "links.foo.title"},
           value: %{description: "Any JSON value."},
           if_match: %{type: :integer, minimum: 1}
         },
         required: [:path, :value]
       }, description: "Entry path + value (+ optional CAS revision)"},
    responses: [
      ok: {@write_ack_schema, description: "Write accepted"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      precondition_failed: {@conflict_schema, description: "If-Match revision mismatch"},
      too_many_requests: @rate_limited
    ]

  def create(conn, %{"org" => org_slug, "store" => store_name} = params) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with {:ok, path} <- fetch_body_path(params),
         {:ok, value} <- fetch_body_value(params),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_write(principal),
         {:ok, attrs} <- build_body_put_attrs(conn, path, value, params, principal) do
      write_and_respond(conn, store, path, attrs)
    end
  end

  operation :destroy,
    operation_id: "entries.destroy",
    summary: "Delete an entry with the path in the request body",
    description: """
    Same semantics as `DELETE /entries/{path}`, but the path travels
    in the request body. Body: `{"path": "links.foo", "if_match"?: <int>}`.
    """,
    tags: ["Entries"],
    parameters: @org_store_params ++ @request_id_param,
    request_body:
      {%{
         type: :object,
         properties: %{
           path: %{type: :string, example: "links.foo"},
           if_match: %{type: :integer, minimum: 1}
         },
         required: [:path]
       }, description: "Entry path (+ optional CAS revision)"},
    responses: [
      ok: {@write_ack_schema, description: "Delete accepted"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      precondition_failed: {@conflict_schema, description: "If-Match revision mismatch"},
      too_many_requests: @rate_limited
    ]

  def destroy(conn, %{"org" => org_slug, "store" => store_name} = params) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with {:ok, path} <- fetch_body_path(params),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_write(principal),
         {:ok, attrs} <- build_body_delete_attrs(conn, path, params, principal) do
      write_and_respond(conn, store, path, attrs)
    end
  end

  defp fetch_body_path(%{"path" => path}) when is_binary(path) and path != "" do
    case DustProtocol.Path.LegacyDot.normalize(path) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_params, "invalid path (#{reason})"}}
    end
  end

  defp fetch_body_path(_),
    do: {:error, {:invalid_params, "'path' field required in body (non-empty string)"}}

  defp fetch_body_value(%{"value" => value}), do: {:ok, value}

  defp fetch_body_value(_),
    do:
      {:error,
       {:invalid_params,
        "'value' field required in body. To remove an entry use DELETE /entries with the path in the body."}}

  defp build_body_put_attrs(conn, path, value, params, principal) do
    base = %{
      op: :set,
      path: path,
      value: value,
      device_id: ApiPrincipal.device_id(principal),
      client_op_id: request_op_id(conn)
    }

    case body_if_match(params) do
      {:ok, :none} -> {:ok, base}
      {:ok, n} -> {:ok, Map.put(base, :if_match, n)}
      err -> err
    end
  end

  defp build_body_delete_attrs(conn, path, params, principal) do
    base = %{
      op: :delete,
      path: path,
      device_id: ApiPrincipal.device_id(principal),
      client_op_id: request_op_id(conn)
    }

    case body_if_match(params) do
      {:ok, :none} -> {:ok, base}
      {:ok, n} -> {:ok, Map.put(base, :if_match, n)}
      err -> err
    end
  end

  defp body_if_match(%{"if_match" => n}) when is_integer(n) and n > 0, do: {:ok, n}

  defp body_if_match(%{"if_match" => other}),
    do:
      {:error,
       {:invalid_params, "if_match must be a positive integer (got #{inspect(other)})"}}

  defp body_if_match(_), do: {:ok, :none}

  defp build_delete_attrs(conn, path, principal) do
    base = %{
      op: :delete,
      path: path,
      device_id: ApiPrincipal.device_id(principal),
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
        {:error,
         {:invalid_params,
          "request body is empty. To write a JSON null value, send the literal string \"null\" with content-type: application/json. To remove an entry, use DELETE."}}

      map when is_map(map) ->
        {:ok, map}
    end
  end

  defp build_put_attrs(conn, path, value, principal) do
    base = %{
      op: :set,
      path: path,
      value: value,
      device_id: ApiPrincipal.device_id(principal),
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

  defp verify_can_write(principal) do
    if ApiPrincipal.can_write?(principal), do: :ok, else: {:error, :forbidden}
  end

  operation :batch,
    operation_id: "entries.batch_get",
    summary: "Read multiple entries in one request",
    description:
      "Returns found entries keyed by canonical (dotted) path, plus a `missing` list of paths that did not match an entry. Up to 1000 paths per call.",
    tags: ["Entries"],
    parameters: @org_store_params ++ @request_id_param,
    request_body:
      {%{
         type: :object,
         properties: %{
           paths: %{
             type: :array,
             items: %{type: :string},
             maxItems: 1000,
             description:
               "Up to 1000 entry paths. Slashes are accepted as aliases for dots; canonical (dotted) keys are returned."
           }
         },
         required: [:paths],
         example: %{paths: ["projects/alpha/title", "projects/alpha/owner"]}
       }, description: "Batch read request"},
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             entries: %{
               type: :object,
               additionalProperties: @entry_ref,
               description: "Map keyed by canonical (dotted) path."
             },
             missing: %{
               type: :array,
               items: %{type: :string},
               description: "Paths that did not match an entry."
             }
           },
           required: [:entries, :missing]
         }, description: "Batch result"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      too_many_requests: @rate_limited
    ]

  def batch(conn, %{"org" => org_slug, "store" => store_name} = params) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with {:ok, paths} <- parse_batch_paths(params),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_read(principal) do
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
        normalize_batch_paths(paths)
    end
  end

  defp parse_batch_paths(_), do: {:error, {:invalid_params, "paths required"}}

  defp normalize_batch_paths(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case DustProtocol.Path.LegacyDot.normalize(path) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        {:error, _} ->
          {:halt, {:error, {:invalid_params, "invalid path: #{inspect(path)}"}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp render_batch_entries(entries) do
    Map.new(entries, fn {path, %{value: v, type: t, seq: s}} ->
      {path, %{value: v, type: t, revision: s}}
    end)
  end

  operation :batch_write,
    operation_id: "entries.batch_write",
    summary: "Atomic multi-key write — all-or-nothing",
    description: """
    Apply up to 1000 writes (set + delete) in a single sqlite
    transaction. Either every op is committed (each with its own
    monotonic `store_seq`), or none are — there is no partial
    application.

    Each op may carry an `if_match` precondition; if any op's CAS
    check fails, the whole batch aborts with `412` and zero ops are
    applied. CAS rules match `entries.put` and `entries.delete`:
    leaf-only, supported on `set` and `delete` ops.

    Subscribers receive one event per op, in order.
    """,
    tags: ["Entries"],
    parameters: @org_store_params ++ @request_id_param,
    request_body:
      {%{
         type: :object,
         properties: %{
           ops: %{
             type: :array,
             maxItems: 1000,
             items: %{
               type: :object,
               properties: %{
                 op: %{type: :string, enum: ["set", "delete"]},
                 path: %{type: :string, description: "Slashes accepted; canonical is dotted."},
                 value: %{description: "Required for set; ignored for delete."},
                 if_match: %{type: :integer, description: "Optional leaf-only CAS precondition."}
               },
               required: [:op, :path]
             }
           }
         },
         required: [:ops],
         example: %{
           ops: [
             %{op: "set", path: "projects/alpha/title", value: "Alpha"},
             %{op: "set", path: "projects/alpha/owner", value: "alice"},
             %{op: "delete", path: "projects/legacy"}
           ]
         }
       }, description: "Batch write request"},
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             ops: %{
               type: :array,
               items: %{
                 type: :object,
                 properties: %{
                   path: %{type: :string},
                   revision: %{type: :integer},
                   store_seq: %{type: :integer}
                 },
                 required: [:path, :revision, :store_seq]
               }
             },
             store_seq: %{
               type: :integer,
               description: "Last store_seq assigned in the batch."
             }
           },
           required: [:ops, :store_seq]
         }, description: "All ops committed"},
      bad_request: @bad_request,
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      precondition_failed:
        {%{
           type: :object,
           properties: %{
             error: %{type: :string, enum: ["conflict"]},
             op_index: %{type: :integer},
             path: %{type: :string},
             current_revision: %{type: ["integer", "null"]}
           },
           required: [:error, :op_index, :path]
         }, description: "An op's If-Match precondition failed; no ops applied."},
      too_many_requests: @rate_limited
    ]

  def batch_write(conn, %{"org" => org_slug, "store" => store_name} = params) do
    principal = conn.assigns.api_principal
    organization = principal.organization

    with {:ok, ops} <- parse_batch_write_ops(conn, params, principal),
         :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- verify_principal_scope(principal, store),
         :ok <- verify_can_write(principal) do
      case Sync.batch_write(store.id, ops) do
        {:ok, results} ->
          last_seq = results |> List.last() |> case do
            %{store_seq: s} -> s
            _ -> 0
          end

          json(conn, %{
            ops:
              Enum.map(results, fn %{store_seq: s, path: p} ->
                %{path: p, revision: s, store_seq: s}
              end),
            store_seq: last_seq
          })

        {:error, {:conflict, %{op_index: i, path: p, current_revision: rev}}} ->
          conn
          |> put_status(412)
          |> json(%{error: "conflict", op_index: i, path: p, current_revision: rev})

        {:error, {:if_match_unsupported_op, %{op_index: i, path: p}}} ->
          conn
          |> put_status(400)
          |> json(%{
            error: "if_match_unsupported_op",
            op_index: i,
            path: p,
            detail: "If-Match is only supported for set and delete ops"
          })

        {:error, {:if_match_multi_leaf, %{op_index: i, path: p}}} ->
          conn
          |> put_status(400)
          |> json(%{
            error: "if_match_multi_leaf",
            op_index: i,
            path: p,
            detail: "If-Match requires a leaf value, not a map/dict"
          })

        {:error, reason} ->
          conn
          |> put_status(400)
          |> json(%{error: "invalid_params", detail: inspect(reason)})
      end
    end
  end

  defp parse_batch_write_ops(conn, %{"ops" => ops}, principal) when is_list(ops) do
    cond do
      length(ops) == 0 ->
        {:error, {:invalid_params, "ops cannot be empty"}}

      length(ops) > 1000 ->
        {:error, {:invalid_params, "maximum 1000 ops per batch"}}

      true ->
        ops
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
          case parse_single_batch_op(conn, raw, principal, index) do
            {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
            err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          err -> err
        end
    end
  end

  defp parse_batch_write_ops(_conn, _params, _principal),
    do: {:error, {:invalid_params, "ops array required"}}

  defp parse_single_batch_op(conn, raw, principal, index) when is_map(raw) do
    with {:ok, op} <- parse_batch_op_kind(raw, index),
         {:ok, path} <- parse_batch_op_path(raw, index),
         {:ok, attrs} <- build_batch_op_attrs(conn, op, path, raw, principal, index) do
      {:ok, attrs}
    end
  end

  defp parse_single_batch_op(_conn, _other, _principal, index),
    do: {:error, {:invalid_params, "op #{index} must be an object"}}

  defp parse_batch_op_kind(%{"op" => "set"}, _), do: {:ok, :set}
  defp parse_batch_op_kind(%{"op" => "delete"}, _), do: {:ok, :delete}

  defp parse_batch_op_kind(%{"op" => other}, index),
    do: {:error, {:invalid_params, "op #{index}: unknown op #{inspect(other)}"}}

  defp parse_batch_op_kind(_, index),
    do: {:error, {:invalid_params, "op #{index}: missing 'op' field"}}

  defp parse_batch_op_path(%{"path" => path}, index) when is_binary(path) do
    case DustProtocol.Path.LegacyDot.normalize(path) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_params, "op #{index}: invalid path (#{reason})"}}
    end
  end

  defp parse_batch_op_path(_, index),
    do: {:error, {:invalid_params, "op #{index}: 'path' required and must be a string"}}

  defp build_batch_op_attrs(conn, :set, path, raw, principal, index) do
    with {:ok, value} <- fetch_set_value(raw, index),
         {:ok, if_match} <- parse_batch_if_match(raw, index) do
      attrs = %{
        op: :set,
        path: path,
        value: value,
        device_id: ApiPrincipal.device_id(principal),
        client_op_id: "#{request_op_id(conn)}:#{index}"
      }

      {:ok, attach_if_match(attrs, if_match)}
    end
  end

  defp build_batch_op_attrs(conn, :delete, path, raw, principal, index) do
    with {:ok, if_match} <- parse_batch_if_match(raw, index) do
      attrs = %{
        op: :delete,
        path: path,
        device_id: ApiPrincipal.device_id(principal),
        client_op_id: "#{request_op_id(conn)}:#{index}"
      }

      {:ok, attach_if_match(attrs, if_match)}
    end
  end

  defp fetch_set_value(raw, index) do
    case Map.fetch(raw, "value") do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_params, "op #{index}: 'value' required for set"}}
    end
  end

  # A present-but-invalid `if_match` must reject the batch with 400 —
  # silently dropping the precondition would turn a CAS write into an
  # unconditional one, which is exactly the failure mode CAS exists
  # to prevent. Absent if_match is fine and yields `:none`.
  defp parse_batch_if_match(raw, index) do
    case Map.fetch(raw, "if_match") do
      :error ->
        {:ok, :none}

      {:ok, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:ok, other} ->
        {:error,
         {:invalid_params,
          "op #{index}: if_match must be a positive integer (got #{inspect(other)})"}}
    end
  end

  defp attach_if_match(attrs, :none), do: attrs
  defp attach_if_match(attrs, n) when is_integer(n), do: Map.put(attrs, :if_match, n)

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
        conn
        |> put_status(400)
        |> json(%{
          error: "invalid_pattern_for_prefixes",
          detail:
            "select=prefixes accepts only `**` (every top-level prefix) or a `<base>.**` pattern (every direct-child prefix under <base>). Other patterns are rejected because the prefix projection is not well-defined for them."
        })

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

  defp parse_from(%{"from" => f}) when is_binary(f) and f != "" do
    case DustProtocol.Path.LegacyDot.normalize(f) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _} -> {:error, {:invalid_params, "from must be a valid path"}}
    end
  end

  defp parse_from(_), do: {:error, {:invalid_params, "from must be a non-empty string"}}

  defp parse_to(%{"to" => t}) when is_binary(t) and t != "" do
    case DustProtocol.Path.LegacyDot.normalize(t) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _} -> {:error, {:invalid_params, "to must be a valid path"}}
    end
  end

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

  defp verify_principal_scope(principal, store) do
    if ApiPrincipal.scopes_store?(principal, store), do: :ok, else: {:error, :forbidden}
  end

  defp verify_can_read(principal) do
    if ApiPrincipal.can_read?(principal), do: :ok, else: {:error, :forbidden}
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

  defp parse_pattern(%{"pattern" => p}) when is_binary(p) and p != "" do
    case DustProtocol.Path.LegacyDot.normalize_pattern(p) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _} -> {:error, {:invalid_params, "pattern has empty segments"}}
    end
  end

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
