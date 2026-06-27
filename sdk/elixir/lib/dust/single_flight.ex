defmodule Dust.SingleFlight do
  @moduledoc """
  Coordinated distributed cache-fill (a.k.a. single-flight) over a Dust lease.

  For a key `K`, one caller in the fleet runs the expensive `fun` while every
  other caller rides the published result. Read-through, cache, memoize: this
  is the "compute once, share many" primitive.

  **It is at-least-once / single-flight *while Dust is reachable*, NOT
  exactly-once.** `lease_ttl` expiry mid-run, a crash before publish, or the
  `on_unavailable: :run_local` degrade can all cause a second run. `fun` MUST
  be idempotent, published values MUST be small pointers (the bytes belong in
  S3/your DB), and followers MUST apply results idempotently.

  See `Dust.single_flight/4`.
  """

  alias Dust.Flight

  @default_lease_ttl 30_000
  @heartbeat_divisor 3
  @max_backoff_ms 250

  @doc """
  Run `fun` under coordination. See `Dust.single_flight/4` for the contract.
  """
  def run(store, key, fun, opts \\ []) when is_function(fun, 1) do
    cfg = build_cfg(key, opts)

    # Fast path: a fresh local hit returns with no network and no lease.
    case fresh_cached(store, key, cfg.fresh) do
      {:ok, value} ->
        {:ok, Flight.new(value: value, source: :cached)}

      _miss_or_stale ->
        coordinate(store, key, fun, cfg, monotonic_deadline(cfg.wait_timeout))
    end
  end

  # --- Coordination loop ---

  defp coordinate(store, key, fun, cfg, deadline) do
    case Dust.lease(store, cfg.lock_key, ttl_ms: cfg.lease_ttl) do
      {:ok, lease} ->
        won(store, key, fun, lease, cfg)

      {:error, :held} ->
        case await(store, key, cfg, deadline) do
          {:ok, flight} ->
            {:ok, flight}

          # The holder released, or its lease may now be stealable — try to
          # (re-)acquire, with a jittered backoff so waiters don't re-claim the
          # single writer in lockstep. Bounded by the overall deadline.
          :retry ->
            if remaining_ms(deadline) > 0 do
              Process.sleep(min(backoff(), remaining_ms(deadline)))
              coordinate(store, key, fun, cfg, deadline)
            else
              on_timeout(store, key, cfg)
            end
        end

      {:error, :unavailable} ->
        degraded(store, key, fun, cfg)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Winner: run fun under a heartbeat-renewed lease, publish fenced ---

  defp won(store, key, fun, lease, cfg) do
    hb = start_heartbeat(store, lease, cfg.lease_ttl)

    # No rescue (house rule): if fun raises, this process dies, the linked
    # heartbeat dies with it, renewals stop, and the lease expires at
    # lease_ttl — others re-elect. That is the documented recovery bound.
    result = fun.(lease)
    stop_heartbeat(hb)

    case result do
      {:publish, value} ->
        case Dust.put(store, key, encode(value), fence: lease) do
          {:ok, _seq} ->
            _ = Dust.release(store, lease)
            {:ok, Flight.new(value: normalize(value), source: :computed)}

          {:error, :fenced} ->
            # We lost the lease mid-run; a newer holder owns the result now.
            {:error, :fenced}

          {:error, other} ->
            _ = Dust.release(store, lease)
            {:error, other}
        end

      {:abort, reason} ->
        _ = Dust.release(store, lease)
        {:error, reason}

      other ->
        _ = Dust.release(store, lease)

        raise ArgumentError,
              "single_flight fun must return {:publish, value} | {:abort, reason}, got: #{inspect(other)}"
    end
  end

  # --- Loser: await the winner's result (or a release → re-elect) ---

  defp await(store, key, cfg, deadline) do
    parent = self()

    # Subscribe to BOTH the result key (winner published) and the lock key
    # (winner released/expired → re-elect) BEFORE re-reading, to close the
    # lost-wakeup window. monitor: true auto-cleans if this caller dies.
    kref =
      Dust.on(store, key, fn ev -> send(parent, {:sf_key, ev}) end,
        monitor: true,
        mode: :committed
      )

    lref =
      Dust.on(store, cfg.lock_key, fn ev -> send(parent, {:sf_lock, ev}) end,
        monitor: true,
        mode: :committed
      )

    result =
      case fresh_cached(store, key, cfg.fresh) do
        {:ok, value} ->
          {:ok, Flight.new(value: value, source: :awaited)}

        _ ->
          # Wait at most until the soonest a crashed holder's lease could become
          # stealable (lease_ttl), bounded by the overall deadline. On expiry we
          # return :retry so the coordinator re-attempts the (now stealable)
          # lease rather than giving up — that is how a dead winner is taken over.
          wait = min(cfg.lease_ttl, remaining_ms(deadline))
          if wait <= 0, do: :retry, else: wait_loop(store, key, cfg, monotonic_deadline(wait))
      end

    Dust.off(store, kref)
    Dust.off(store, lref)
    flush_sf_messages()
    result
  end

  defp wait_loop(store, key, cfg, until) do
    remaining = remaining_ms(until)

    if remaining <= 0 do
      :retry
    else
      receive do
        {:sf_key, _ev} ->
          # Re-validate the predicate on every wake — an event passing the gate
          # (e.g. a delete) does not by itself mean "fresh value present".
          case fresh_cached(store, key, cfg.fresh) do
            {:ok, value} -> {:ok, Flight.new(value: value, source: :awaited)}
            _ -> wait_loop(store, key, cfg, until)
          end

        {:sf_lock, ev} ->
          if lock_released?(ev), do: :retry, else: wait_loop(store, key, cfg, until)
      after
        remaining -> :retry
      end
    end
  end

  # A committed release of the lock key means the fill ended without a fresh
  # result reaching us → re-elect. (A steal arrives as an :lease event, not a
  # release: a new holder exists, so keep awaiting the result instead.)
  defp lock_released?(%{op: :release}), do: true
  defp lock_released?(_), do: false

  defp on_timeout(store, key, cfg) do
    # Freshness mode with a last-known value → serve it stale rather than fail.
    case last_value(store, key) do
      {:ok, value} when cfg.fresh != nil ->
        {:ok, Flight.new(value: value, source: :cached, stale?: true)}

      _ ->
        {:error, :timeout}
    end
  end

  # --- Degraded: Dust unreachable ---

  defp degraded(_store, _key, _fun, %{on_unavailable: :error}), do: {:error, :unavailable}

  defp degraded(store, key, fun, %{on_unavailable: :run_local}) do
    # No lease available — run uncoordinated (possible duplicate work across
    # nodes; documented). In-node duplicate suppression would need the
    # coalescing Registry (deferred).
    case fun.(nil) do
      {:publish, value} ->
        _ = best_effort_put(store, key, encode(value))
        {:ok, Flight.new(value: normalize(value), source: :computed, coordinated?: false)}

      {:abort, reason} ->
        {:error, reason}

      other ->
        raise ArgumentError,
              "single_flight fun must return {:publish, value} | {:abort, reason}, got: #{inspect(other)}"
    end
  end

  # --- Heartbeat (keep the lease alive for the duration of fun) ---

  defp start_heartbeat(store, lease, ttl) do
    interval = max(div(ttl, @heartbeat_divisor), 1)
    spawn_link(fn -> heartbeat_loop(store, lease, ttl, interval) end)
  end

  defp heartbeat_loop(store, lease, ttl, interval) do
    receive do
      :stop -> :ok
    after
      interval ->
        case Dust.renew(store, lease, ttl_ms: ttl) do
          {:ok, _} -> heartbeat_loop(store, lease, ttl, interval)
          # Lost the lease (stolen/expired) or unavailable — stop renewing.
          {:error, _} -> :ok
        end
    end
  end

  defp stop_heartbeat(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    :ok
  end

  # --- Cache reads / value codec ---

  # The published value is stored JSON-encoded as a scalar leaf so Dust's
  # plain-map flattening doesn't shred a pointer into a subtree. Every reader
  # (fast path, await, on_timeout) decodes it, so all sources return the same
  # shape.
  defp fresh_cached(store, key, fresh) do
    case last_value(store, key) do
      {:ok, value} ->
        if fresh == nil or fresh.(value), do: {:ok, value}, else: :stale

      :absent ->
        :absent
    end
  end

  defp last_value(store, key) do
    case Dust.entry(store, key) do
      {:ok, %Dust.Entry{value: raw, type: type}} when type != "lease" and is_binary(raw) ->
        {:ok, Jason.decode!(raw)}

      _ ->
        :absent
    end
  end

  defp encode(value), do: Jason.encode!(value)
  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()

  # put/3 is fire-and-forget (optimistic local write + queued op; returns :ok
  # even when disconnected), so a degraded publish never blocks or crashes the
  # local computation — no rescue needed.
  defp best_effort_put(store, key, encoded) do
    Dust.put(store, key, encoded)
  end

  # --- Config + time helpers ---

  defp build_cfg(key, opts) do
    lease_ttl = Keyword.get(opts, :lease_ttl, @default_lease_ttl)

    %{
      fresh: Keyword.get(opts, :fresh?),
      lease_ttl: lease_ttl,
      wait_timeout: Keyword.get(opts, :wait_timeout, lease_ttl + 5_000),
      on_unavailable: Keyword.get(opts, :on_unavailable, :run_local),
      lock_key: Keyword.get(opts, :lock_key, "_dust:sf/" <> key)
    }
  end

  defp monotonic_deadline(ms), do: System.monotonic_time(:millisecond) + ms
  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)
  defp backoff, do: :rand.uniform(@max_backoff_ms)

  defp flush_sf_messages do
    receive do
      {:sf_key, _} -> flush_sf_messages()
      {:sf_lock, _} -> flush_sf_messages()
    after
      0 -> :ok
    end
  end
end
