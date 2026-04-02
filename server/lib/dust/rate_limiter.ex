defmodule Dust.RateLimiter do
  @moduledoc """
  Per-token rate limiting using Hammer (ETS-backed token bucket).

  Limits are keyed by store_token.id so all connections sharing
  a token share the same rate limit.
  """

  @write_limit Application.compile_env(:dust, :rate_limit_writes_per_min, 100)
  @read_limit Application.compile_env(:dust, :rate_limit_reads_per_min, 1000)

  def check(token_id, :write) do
    check_rate("write:#{token_id}", @write_limit, 60_000)
  end

  def check(token_id, :read) do
    check_rate("read:#{token_id}", @read_limit, 60_000)
  end

  defp check_rate(key, limit, window_ms) do
    case Hammer.check_rate(key, window_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _limit} ->
        {:error, :rate_limited, %{retry_after_ms: window_ms}}
    end
  end
end
