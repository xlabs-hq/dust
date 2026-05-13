defmodule DustWeb.Api.RealtimeController do
  @moduledoc """
  Stub endpoints that point users at the WebSocket realtime protocol
  rather than 404'ing on obvious guesses like `/subscribe` or `/watch`.

  Returns 426 Upgrade Required with a body explaining where to go.
  """

  use DustWeb, :controller
  use Oaskit.Controller

  alias DustWeb.Api.Refs

  @rate_limited Refs.rate_limited()
  @unauthorized Refs.unauthorized()
  @forbidden Refs.forbidden()

  @org_store_params [
    _: Refs.parameter("OrgSlug"),
    _: Refs.parameter("StoreName")
  ]

  @upgrade_response_schema %{
    type: :object,
    properties: %{
      error: %{type: :string, enum: ["upgrade_required"]},
      detail: %{type: :string},
      ws_url: %{type: :string},
      docs: %{type: :string}
    },
    required: [:error, :detail, :ws_url],
    example: %{
      error: "upgrade_required",
      detail: "Realtime is via WebSocket. Connect to ws_url and join store:<org>/<store>.",
      ws_url: "wss://dustlayer.io/ws/sync",
      docs: "https://github.com/xlabs-hq/dust#realtime"
    }
  }

  @stub_description """
  Realtime subscriptions are not exposed over plain HTTP. Connect to
  the Phoenix Channels endpoint at `wss://<host>/ws/sync` and join
  `store:<org>/<store>`. The TypeScript and Elixir SDKs handle this
  automatically.

  Documented separately to remove the "is this feature missing?"
  moment when users try `/subscribe` or `/watch` from curl.
  """

  operation(:subscribe,
    operation_id: "realtime.subscribe_stub",
    summary: "Realtime subscribe — use WebSocket",
    description: @stub_description,
    tags: ["Realtime"],
    parameters: @org_store_params,
    responses: [
      upgrade_required:
        {@upgrade_response_schema, description: "Pointer to the WebSocket realtime protocol"},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      too_many_requests: @rate_limited
    ]
  )

  def subscribe(conn, params), do: do_stub(conn, params)

  operation(:watch,
    operation_id: "realtime.watch_stub",
    summary: "Realtime watch — use WebSocket",
    description: @stub_description,
    tags: ["Realtime"],
    parameters: @org_store_params,
    responses: [
      upgrade_required:
        {@upgrade_response_schema, description: "Pointer to the WebSocket realtime protocol"},
      unauthorized: @unauthorized,
      forbidden: @forbidden,
      too_many_requests: @rate_limited
    ]
  )

  def watch(conn, params), do: do_stub(conn, params)

  defp do_stub(conn, _params) do
    ws_url =
      conn
      |> request_url()
      |> URI.parse()
      |> Map.put(:scheme, if(conn.scheme == :https, do: "wss", else: "ws"))
      |> Map.put(:path, "/ws/sync")
      |> Map.put(:query, nil)
      |> URI.to_string()

    conn
    |> put_status(426)
    |> json(%{
      error: "upgrade_required",
      detail:
        "Realtime is via WebSocket. Connect to ws_url and join the topic store:<org>/<store>. The TypeScript and Elixir SDKs handle this automatically.",
      ws_url: ws_url,
      docs: "https://github.com/xlabs-hq/dust#realtime"
    })
  end
end
