defmodule DustWeb.ApiSpec do
  @moduledoc """
  Top-level OpenAPI 3.1 spec for the Dust HTTP API.

  Per-operation details live as `operation` annotations on each
  controller action; this module provides:

  * shared response shapes (`Unauthorized`, `Forbidden`, etc.)
  * shared header parameters (`If-Match`, `X-Request-Id`)
  * shared schemas (`Error`, `Pagination`, `Entry`, `Store`, `Token`,
    `Webhook`, `WebhookDelivery`)
  * the `webhooks` top-level section documenting outbound delivery
    payloads
  * a post-pass that rewrites Phoenix glob routes (`*path`) into
    OpenAPI-valid `{path}` parameters — `Oaskit.Spec.Paths.from_router/2`
    doesn't handle `*` segments natively.

  Browse at `/api-docs` (Redoc UI) or fetch the JSON at `/openapi.json`.
  """
  use Oaskit

  alias Oaskit.Spec.Paths

  @impl true
  def spec do
    paths =
      DustWeb.Router
      |> Paths.from_router(filter: &String.starts_with?(&1.path, "/api/"))
      |> normalize_glob_paths()
      |> inject_common_response_headers()

    %{
      openapi: "3.1.1",
      info: %{
        title: "Dust API",
        version: "0.1.0",
        description: """
        HTTP API for [Dust](https://dustlayer.io) — reactive global state
        for AI agents.

        ### Stability

        **This is a pre-1.0 API.** Breaking changes are possible
        between minor versions. The current version is published in
        `info.version`; consumers should pin to that and watch
        [GitHub releases](https://github.com/xlabs-hq/dust/releases)
        for migration notes.

        Versioned URLs (`/v1/...`), `Deprecation`/`Sunset` headers
        (RFC 9745), and a written deprecation policy will arrive at
        1.0. Until then: treat this as a beta contract.

        ### Authentication

        All endpoints require a Bearer token in the `Authorization`
        header. Create tokens at `/:org/tokens` in the dashboard.

        Tokens are scoped to a single store and carry `read` and/or
        `write` permissions:

        * **`read`** — read entries, list webhooks/audit log, export.
        * **`read+write`** — additionally write entries, register
          webhooks, run import/clone/diff, and manage tokens **for
          the same store**.

        Cross-store operations are not available with API tokens in
        this version: `tokens.create` and `tokens.revoke` only work
        for the calling token's own store, and `stores.create` is
        disabled entirely (dashboard-only). Granular org-admin
        tokens, which will re-enable these flows, are on the roadmap.

        ### CORS

        The REST API is intended for **server-to-server use** in
        v0.1. Browser-origin requests are not in scope and CORS is
        not enabled for arbitrary origins. SDKs that need
        browser-side access should connect via WebSocket (which
        accepts cross-origin connections).

        ### Paths

        Entries are addressed by slash-separated paths
        (`projects/alpha/title`). Each segment is plain text — dots,
        spaces, and other characters are allowed inside a segment. To
        carry a literal `/` or `~` inside a segment, encode it as `~1`
        or `~0` respectively (RFC 6901 JSON Pointer escaping). The URL
        wildcard route accepts those escapes directly:
        `GET /entries/files/image~1logo` resolves to segments
        `["files", "image/logo"]`.

        ### Errors

        Every endpoint may return `401 Unauthorized` (missing/invalid
        token), `403 Forbidden` (token lacks permission), `429 Too Many
        Requests` (rate limited), or `500 Internal Server Error`. Per-
        operation responses below document the operation-specific
        codes (404, 400, 412, etc.) — assume the four common codes
        always apply.

        ### Rate limits

        Per-token rate limits are enforced per minute on two buckets:
        reads (1000/min) and writes (100/min). The `X-RateLimit-Limit`,
        `X-RateLimit-Remaining`, and `X-RateLimit-Reset` headers are
        returned on every successful response. 429 responses include
        `Retry-After` (seconds).

        ### Request IDs

        Send `X-Request-Id` to attach an opaque correlation id; the
        server echoes it back on every response. Useful for support
        tickets and end-to-end tracing. Also used as the
        `client_op_id` fallback for write endpoints if not supplied.

        Source: <https://github.com/xlabs-hq/dust>.
        """,
        contact: %{
          name: "Dust",
          url: "https://github.com/xlabs-hq/dust"
        },
        license: %{
          name: "MIT",
          identifier: "MIT"
        }
      },
      servers: [%{url: "https://dustlayer.io", description: "Production"}],
      paths: paths,
      webhooks: webhooks(),
      components: %{
        securitySchemes: %{
          "bearerAuth" => %{
            type: "http",
            scheme: "bearer",
            description: "Bearer token scoped to a single store."
          }
        },
        schemas: shared_schemas(),
        responses: shared_responses(),
        parameters: shared_parameters(),
        headers: shared_headers()
      },
      security: [%{"bearerAuth" => []}]
    }
  end

  # --- Path post-processing ---

  # Rewrite Phoenix glob captures (`/entries/*path`) into
  # OpenAPI-valid `{path}` form. Slashes inside the path travel as
  # literal slashes in the URL — clients should not URL-encode them.
  defp normalize_glob_paths(paths) do
    Map.new(paths, fn {key, value} ->
      new_key = Regex.replace(~r{/\*(\w+)}, key, "/{\\1}")
      {new_key, value}
    end)
  end

  @common_response_headers %{
    "X-Request-Id" => %Oaskit.Spec.Reference{
      :"$ref" => "#/components/headers/X-Request-Id"
    },
    "X-RateLimit-Limit" => %Oaskit.Spec.Reference{
      :"$ref" => "#/components/headers/X-RateLimit-Limit"
    },
    "X-RateLimit-Remaining" => %Oaskit.Spec.Reference{
      :"$ref" => "#/components/headers/X-RateLimit-Remaining"
    },
    "X-RateLimit-Reset" => %Oaskit.Spec.Reference{
      :"$ref" => "#/components/headers/X-RateLimit-Reset"
    }
  }

  # Walk each per-operation inline response and add the common headers.
  # Skips Reference responses (those are shared and have headers added
  # at the component level instead).
  defp inject_common_response_headers(paths) do
    Map.new(paths, fn {path, methods} ->
      methods =
        Map.new(methods, fn {verb, op} ->
          {verb, inject_into_op(op)}
        end)

      {path, methods}
    end)
  end

  defp inject_into_op(%Oaskit.Spec.Operation{responses: responses} = op)
       when is_map(responses) do
    new_responses =
      Map.new(responses, fn {status, resp} -> {status, add_headers(resp)} end)

    %{op | responses: new_responses}
  end

  defp inject_into_op(op), do: op

  defp add_headers(%Oaskit.Spec.Reference{} = ref), do: ref

  defp add_headers(%Oaskit.Spec.Response{headers: existing} = resp) do
    %{resp | headers: Map.merge(@common_response_headers, existing || %{})}
  end

  defp add_headers(other), do: other

  # --- Shared schemas ---

  defp shared_schemas do
    %{
      "Error" => %{
        type: :object,
        description: "Standard error envelope.",
        properties: %{
          error: %{
            type: :string,
            description: "Machine-readable error code (e.g. `not_found`, `invalid_params`)."
          },
          detail: %{type: :string, description: "Human-readable explanation, when applicable."}
        },
        required: [:error],
        example: %{error: "invalid_params", detail: "name is required"}
      },
      "ValidationError" => %{
        type: :object,
        description: "Returned when the request body fails schema validation.",
        properties: %{
          error: %{
            type: :object,
            description: "Field-keyed map of error messages.",
            additionalProperties: %{type: :array, items: %{type: :string}}
          }
        },
        required: [:error],
        example: %{error: %{name: ["has already been taken"]}}
      },
      "Pagination" => %{
        type: :object,
        description: "Page metadata for cursor-paginated responses.",
        properties: %{
          page: %{type: :integer},
          limit: %{type: :integer},
          total: %{type: :integer},
          total_pages: %{type: :integer}
        },
        required: [:page, :limit, :total, :total_pages]
      },
      "Entry" => %{
        type: :object,
        description: "A single key/value entry in a store.",
        properties: %{
          path: %{type: :string, description: "Canonical slash-rendered path."},
          value: %{description: "Entry value (any JSON type, may be null for tombstones)."},
          type: %{
            type: :string,
            enum: [
              "string",
              "integer",
              "float",
              "boolean",
              "map",
              "list",
              "decimal",
              "datetime",
              "file"
            ]
          },
          revision: %{
            type: :integer,
            description: "Per-entry sequence number; use as `If-Match` for CAS."
          }
        },
        required: [:path, :value, :type, :revision],
        example: %{
          path: "projects/alpha/title",
          value: "Project Alpha",
          type: "string",
          revision: 7
        }
      },
      "Store" => %{
        type: :object,
        properties: %{
          id: %{type: :string, format: :uuid},
          name: %{type: :string},
          full_name: %{
            type: :string,
            description: "`org_slug/store_name` — globally unique."
          },
          status: %{type: :string, enum: ["active", "archived"]},
          inserted_at: %{type: :string, format: "date-time"},
          expires_at: %{type: ["string", "null"], format: "date-time"}
        },
        required: [:id, :name, :full_name, :status, :inserted_at]
      },
      "Token" => %{
        type: :object,
        properties: %{
          id: %{type: :string, format: :uuid},
          name: %{type: :string},
          store_name: %{type: :string},
          permissions: %{
            type: :object,
            properties: %{
              read: %{type: :boolean},
              write: %{type: :boolean}
            },
            required: [:read, :write]
          },
          expires_at: %{type: ["string", "null"], format: "date-time"},
          last_used_at: %{type: ["string", "null"], format: "date-time"},
          inserted_at: %{type: :string, format: "date-time"}
        },
        required: [:id, :name, :store_name, :permissions, :inserted_at]
      },
      "Webhook" => %{
        type: :object,
        properties: %{
          id: %{type: :string, format: :uuid},
          url: %{type: :string, format: :uri},
          active: %{type: :boolean},
          failure_count: %{type: :integer},
          last_delivered_seq: %{type: ["integer", "null"]},
          inserted_at: %{type: :string, format: "date-time"}
        },
        required: [:id, :url, :active, :failure_count, :inserted_at]
      },
      "WebhookDelivery" => %{
        type: :object,
        properties: %{
          id: %{type: :string, format: :uuid},
          store_seq: %{type: :integer},
          status_code: %{type: ["integer", "null"]},
          response_ms: %{type: ["integer", "null"]},
          error: %{type: ["string", "null"]},
          attempted_at: %{type: :string, format: "date-time"}
        },
        required: [:id, :store_seq, :attempted_at]
      },
      "AuditOp" => %{
        type: :object,
        properties: %{
          store_seq: %{type: :integer},
          op: %{
            type: :string,
            enum: ["set", "delete", "merge", "increment", "add", "remove"]
          },
          path: %{type: :string},
          value: %{description: "Operation value (any JSON type)."},
          device_id: %{type: :string},
          inserted_at: %{type: :string, format: "date-time"}
        },
        required: [:store_seq, :op, :path, :device_id, :inserted_at]
      },
      "WebhookEvent" => %{
        type: :object,
        description: "Payload delivered to webhook subscribers.",
        properties: %{
          event: %{
            type: :string,
            enum: ["entry.changed", "ping"],
            description: "`entry.changed` for store mutations; `ping` from the test endpoint."
          },
          store: %{type: :string, description: "`org_slug/store_name`."},
          store_seq: %{
            type: :integer,
            description:
              "Monotonic store sequence at the time of the change. Use as the dedup key — delivery is at-least-once."
          },
          path: %{type: :string, description: "Path of the changed entry (omitted for `ping`)."},
          op: %{
            type: :string,
            enum: ["set", "delete", "merge", "increment", "add", "remove"],
            description: "Operation that produced the change (omitted for `ping`)."
          },
          value: %{
            description:
              "Materialised post-write value at `path`. Omitted for `delete` and `ping`."
          },
          device_id: %{
            type: :string,
            description:
              "Identifier of the client that originated the write (omitted for `ping`)."
          },
          timestamp: %{type: :string, format: "date-time"}
        },
        required: [:event, :store, :timestamp]
      }
    }
  end

  # --- Shared response objects ---

  defp shared_responses do
    %{
      "Unauthorized" => %{
        description: "Missing or invalid Bearer token.",
        content: %{
          "application/json" => %{
            schema: %{"$ref": "#/components/schemas/Error"},
            example: %{error: "unauthorized"}
          }
        }
      },
      "Forbidden" => %{
        description: "Token does not have permission for this resource.",
        content: %{
          "application/json" => %{
            schema: %{"$ref": "#/components/schemas/Error"},
            example: %{error: "forbidden"}
          }
        }
      },
      "NotFound" => %{
        description: "The requested resource does not exist.",
        content: %{
          "application/json" => %{
            schema: %{"$ref": "#/components/schemas/Error"},
            example: %{error: "not_found"}
          }
        }
      },
      "BadRequest" => %{
        description: "Malformed request — see `error`/`detail` for specifics.",
        content: %{
          "application/json" => %{
            schema: %{"$ref": "#/components/schemas/Error"},
            example: %{
              error: "invalid_params",
              detail: "limit must be 1..1000"
            }
          }
        }
      },
      "RateLimited" => %{
        description:
          "Too many requests for this token + bucket (read or write). See `Retry-After` and `X-RateLimit-Reset`.",
        content: %{
          "application/json" => %{
            schema: %{"$ref": "#/components/schemas/Error"},
            example: %{error: "rate_limited"}
          }
        },
        headers: %{
          "Retry-After" => %{
            description: "Seconds to wait before retrying.",
            schema: %{type: :integer}
          },
          "X-Request-Id" => %{"$ref": "#/components/headers/X-Request-Id"},
          "X-RateLimit-Limit" => %{"$ref": "#/components/headers/X-RateLimit-Limit"},
          "X-RateLimit-Remaining" => %{"$ref": "#/components/headers/X-RateLimit-Remaining"},
          "X-RateLimit-Reset" => %{"$ref": "#/components/headers/X-RateLimit-Reset"}
        }
      }
    }
  end

  # --- Shared parameters & headers ---

  defp shared_parameters do
    %{
      "OrgSlug" => %{
        name: "org",
        in: :path,
        required: true,
        description: "Organization slug.",
        schema: %{type: :string}
      },
      "StoreName" => %{
        name: "store",
        in: :path,
        required: true,
        description: "Store name within the organization.",
        schema: %{type: :string}
      },
      "EntryPath" => %{
        name: "path",
        in: :path,
        required: true,
        description: """
        Slash-separated entry path. Each `/` separates a logical
        segment; segments are plain text and may contain dots, spaces,
        or any other character. To carry a literal `/` or `~` inside a
        segment, encode it as `~1` or `~0` respectively (RFC 6901
        JSON Pointer escaping).

        **Important for SDK clients:** the segment separator `/`
        travels as a literal slash — do *not* URL-encode it to `%2F`.
        Phoenix splits the trailing path segments and our server
        rejoins them. Only the per-segment characters that are
        URL-unsafe (space, `+`, `?`, `#`, etc.) need percent-encoding;
        `~0` and `~1` are RFC 3986 unreserved and pass through
        unchanged. Some OpenAPI client generators URL-encode path
        parameters by default; you may need to configure them not to.
        """,
        schema: %{type: :string, example: "projects/alpha/title"}
      },
      "RequestId" => %{
        name: "X-Request-Id",
        in: :header,
        required: false,
        description:
          "Opaque correlation ID. Echoed back on the response. Used as the write op's `client_op_id` fallback.",
        schema: %{type: :string}
      },
      "IfMatch" => %{
        name: "If-Match",
        in: :header,
        required: false,
        description: """
        Compare-and-swap precondition. Pass the entry's current
        `revision`; the write fails with 412 if the revision has
        advanced.

        **CAS is leaf-only** (capver 2). Specifically:

        - On `PUT`, the body must be a leaf value (scalar or typed
          single-value). Sending a multi-key map body with `If-Match`
          returns `400 if_match_multi_leaf`.
        - On `PUT` or `DELETE`, if no entry exists at the exact path
          (e.g. the path is an interior subtree node), `If-Match`
          will never match and returns `412 conflict`.
        - Other write ops (`merge`, `increment`, `add`, `remove`) over
          the WebSocket channel reject `If-Match` with
          `400 if_match_unsupported_op`. (HTTP only exposes `set` /
          `delete` for entries, so this is only visible to channel
          clients.)
        """,
        schema: %{type: :integer}
      }
    }
  end

  defp shared_headers do
    %{
      "X-Request-Id" => %{
        description: "Echoed correlation ID. Generated server-side if not supplied.",
        schema: %{type: :string}
      },
      "X-RateLimit-Limit" => %{
        description: "Maximum requests per window for this token + bucket.",
        schema: %{type: :integer}
      },
      "X-RateLimit-Remaining" => %{
        description: "Requests remaining in the current window.",
        schema: %{type: :integer}
      },
      "X-RateLimit-Reset" => %{
        description: "Seconds until the current window resets.",
        schema: %{type: :integer}
      }
    }
  end

  # --- Outbound webhooks ---

  defp webhooks do
    %{
      "entry.changed" => %{
        description: """
        Delivered to every active webhook subscriber when a store entry
        changes. Signed with HMAC-SHA256 over the raw body using the
        subscription's secret; the signature is sent in the
        `x-dust-signature` header as `sha256=<hex>`.

        Delivery is at-least-once; subscribers should be idempotent
        keyed on `store_seq`. Failed deliveries are retried with
        exponential backoff.
        """,
        post: %{
          summary: "An entry in a subscribed store was created, updated, or deleted",
          operationId: "webhooks.entry_changed",
          requestBody: %{
            description: "Outbound delivery payload.",
            content: %{
              "application/json" => %{
                schema: %{"$ref": "#/components/schemas/WebhookEvent"},
                example: %{
                  event: "entry.changed",
                  store: "acme/config",
                  store_seq: 42,
                  path: "settings.theme",
                  op: "set",
                  value: "dark",
                  device_id: "web:abc123",
                  timestamp: "2026-05-10T12:34:56Z"
                }
              }
            },
            required: true
          },
          parameters: [
            %{
              name: "x-dust-signature",
              in: :header,
              required: true,
              description: "`sha256=<hex>` HMAC of the raw body using the webhook secret.",
              schema: %{type: :string, example: "sha256=fce4b0..."}
            }
          ],
          responses: %{
            "2XX" => %{description: "Subscriber accepted the delivery."}
          }
        }
      }
    }
  end
end
