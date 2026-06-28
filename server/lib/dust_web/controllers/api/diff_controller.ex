defmodule DustWeb.Api.DiffController do
  use DustWeb, :controller
  use Oaskit.Controller

  alias Dust.{Stores, Sync}
  alias DustWeb.Api.Refs
  alias DustWeb.ApiPrincipal

  action_fallback DustWeb.Api.FallbackController

  operation(:show,
    operation_id: "sync.diff",
    summary: "Diff a store between two sequence numbers",
    description:
      "Returns net per-path changes between `from_seq` (exclusive) and `to_seq` (inclusive, defaults to current). Returns 409 if `from_seq` has been compacted away.",
    tags: ["Sync"],
    parameters: [
      _: Refs.parameter("OrgSlug"),
      _: Refs.parameter("StoreName"),
      from_seq: [
        in: :query,
        schema: %{type: :integer, minimum: 0},
        required: true,
        description: "Sequence number to diff from (exclusive)."
      ],
      to_seq: [
        in: :query,
        schema: %{type: :integer, minimum: 0},
        required: false,
        description: "Sequence number to diff to (inclusive). Defaults to current store_seq."
      ],
      _: Refs.parameter("RequestId")
    ],
    responses: [
      ok:
        {%{
           type: :object,
           properties: %{
             from_seq: %{type: :integer},
             to_seq: %{type: :integer},
             changes: %{
               type: :array,
               items: %{
                 type: :object,
                 properties: %{
                   path: %{type: :string},
                   before: %{description: "Value at from_seq (null if absent)."},
                   after: %{description: "Value at to_seq (null if deleted)."}
                 },
                 required: [:path, :before, :after]
               }
             }
           },
           required: [:from_seq, :to_seq, :changes]
         }, description: "Diff result"},
      bad_request: Refs.bad_request(),
      unauthorized: Refs.unauthorized(),
      forbidden: Refs.forbidden(),
      not_found: Refs.not_found(),
      conflict:
        {%{
           type: :object,
           properties: %{
             error: %{type: :string, enum: ["compacted"]},
             earliest_available: %{type: :integer}
           },
           required: [:error, :earliest_available]
         }, description: "from_seq has been compacted away"},
      too_many_requests: Refs.rate_limited()
    ]
  )

  def show(conn, %{"org" => org_slug, "store" => store_name} = params) do
    organization = conn.assigns.organization
    principal = conn.assigns.api_principal

    with :ok <- verify_org(organization, org_slug),
         {:ok, store} <- find_store(organization, store_name),
         :ok <- authorize_store(principal, store, "entries:read"),
         {:ok, from_seq} <- parse_int(params, "from_seq") do
      to_seq = parse_optional_int(params, "to_seq")
      do_diff(conn, store, from_seq, to_seq)
    end
  end

  defp do_diff(conn, store, from_seq, to_seq) do
    case Sync.Diff.changes(store.id, from_seq, to_seq) do
      {:ok, diff} ->
        json(conn, %{
          from_seq: diff.from_seq,
          to_seq: diff.to_seq,
          changes:
            Enum.map(diff.changes, fn c ->
              %{path: c.path, before: c.before, after: c.after}
            end)
        })

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

  defp authorize_store(principal, store, scope) do
    case ApiPrincipal.authorize_store(principal, store, scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp parse_int(params, key) do
    case Map.get(params, key) do
      nil -> {:error, {:invalid_params, "#{key} is required"}}
      val when is_binary(val) -> parse_int_string(val, key)
      val when is_integer(val) -> {:ok, val}
      _ -> {:error, {:invalid_params, "#{key} must be an integer"}}
    end
  end

  defp parse_int_string(val, key) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _ -> {:error, {:invalid_params, "#{key} must be an integer"}}
    end
  end

  defp parse_optional_int(params, key) do
    case Map.get(params, key) do
      nil ->
        nil

      val when is_binary(val) ->
        case Integer.parse(val) do
          {int, ""} -> int
          _ -> nil
        end

      val when is_integer(val) ->
        val

      _ ->
        nil
    end
  end
end
