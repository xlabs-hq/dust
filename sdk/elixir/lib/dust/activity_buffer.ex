defmodule Dust.ActivityBuffer do
  @moduledoc """
  ETS-backed circular buffer for recent Dust operations.

  Stores the last 100 events per store for dashboard display.
  Append is a direct ETS write — no GenServer serialization on the hot path.
  """

  @max_entries 100

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set])
      _ref -> :ok
    end

    :ignore
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:name]},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  def append(name, store, attrs) do
    entry = Map.merge(attrs, %{
      timestamp: DateTime.utc_now(),
      store: store
    })

    # Get and increment the per-store index
    idx = :ets.update_counter(name, {:idx, store}, {2, 1}, {{:idx, store}, 0})
    slot = rem(idx - 1, @max_entries)

    :ets.insert(name, {{store, slot}, entry})
    :ok
  end

  def recent(name, store, limit \\ @max_entries) do
    # Read up to @max_entries slots for this store
    entries =
      for slot <- 0..(@max_entries - 1),
          [{_key, entry}] <- [:ets.lookup(name, {store, slot})],
          do: entry

    entries
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.take(limit)
  end
end
