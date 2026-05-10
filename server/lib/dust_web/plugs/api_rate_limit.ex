defmodule DustWeb.Plugs.ApiRateLimit do
  @moduledoc """
  Per-token rate limiting for the REST API. Mirrors the WebSocket
  channel's rate limit (`Dust.RateLimiter`) so HTTP and WS share a
  single bucket per token.

  Reads (GET) consume from the read bucket; everything else from the
  write bucket. On allowed requests, emits `X-RateLimit-{Limit,
  Remaining,Reset}` headers. On denied requests, returns 429 with
  `Retry-After` and the same rate-limit headers.

  Must run **after** `DustWeb.Plugs.ApiTokenAuth` so the store_token
  is on the conn.
  """

  import Plug.Conn

  alias Dust.RateLimiter

  @write_limit Application.compile_env(:dust, :rate_limit_writes_per_min, 100)
  @read_limit Application.compile_env(:dust, :rate_limit_reads_per_min, 1000)
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:store_token] do
      nil ->
        # Token plug didn't run / failed — let downstream handle the 401.
        conn

      token ->
        bucket = bucket_for(conn.method)
        limit = limit_for(bucket)
        key = "#{bucket}:#{token.id}"

        case RateLimiter.hit(key, @window_ms, limit) do
          {:allow, count} ->
            conn
            |> put_rate_headers(limit, max(limit - count, 0), reset_seconds())

          {:deny, retry_after_ms} ->
            retry_seconds = div(retry_after_ms, 1000)

            conn
            |> put_rate_headers(limit, 0, retry_seconds)
            |> put_resp_header("retry-after", to_string(retry_seconds))
            |> put_resp_content_type("application/json")
            |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
            |> halt()
        end
    end
  end

  defp bucket_for("GET"), do: :read
  defp bucket_for("HEAD"), do: :read
  defp bucket_for(_), do: :write

  defp limit_for(:read), do: @read_limit
  defp limit_for(:write), do: @write_limit

  defp reset_seconds, do: div(@window_ms, 1000)

  defp put_rate_headers(conn, limit, remaining, reset) do
    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset))
  end
end
