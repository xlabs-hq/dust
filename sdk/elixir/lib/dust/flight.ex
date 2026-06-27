defmodule Dust.Flight do
  @moduledoc """
  The result of `Dust.single_flight/4`.

  - `value` — the materialized result (same shape regardless of `source`).
  - `source` — provenance: `:cached` (fresh local hit, no work), `:computed`
    (this caller ran `fun`), or `:awaited` (another filler ran it; this caller
    rode the result).
  - `stale?` — `true` only when a freshness-mode wait timed out and the last
    known (stale) value is returned rather than a fresh one.
  - `coordinated?` — `false` only on the degraded `on_unavailable: :run_local`
    path, where `fun` ran without a lease (possible duplicate work). This is
    the one signal that idempotency actually mattered on this call.
  """

  @type source :: :cached | :computed | :awaited

  @type t :: %__MODULE__{
          value: term(),
          source: source(),
          stale?: boolean(),
          coordinated?: boolean()
        }

  defstruct [:value, :source, stale?: false, coordinated?: true]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      value: Keyword.fetch!(opts, :value),
      source: Keyword.fetch!(opts, :source),
      stale?: Keyword.get(opts, :stale?, false),
      coordinated?: Keyword.get(opts, :coordinated?, true)
    }
  end
end
