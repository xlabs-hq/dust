defmodule Dust.CallbackRegistry do
  @default_max_queue_size 1000

  def new do
    :ets.new(:dust_callbacks, [:bag, :public])
  end

  @doc """
  Register a callback for a store/pattern with options.

  Options:
    - `:max_queue_size` - maximum pending events before the subscription is
      dropped (default: 1000)
    - `:on_resync` - callback invoked with `%{error: :resync_required, ref: ref}`
      when the subscription is dropped due to backpressure

  Each registration spawns a `Dust.CallbackWorker` process that receives events
  asynchronously. The dispatcher checks the worker's mailbox length before
  sending; if it exceeds `max_queue_size`, the subscription is unregistered and
  `on_resync` fires.
  """
  def register(table, store, pattern, callback, opts \\ []) when is_function(callback, 1) do
    ref = make_ref()
    compiled = Dust.Protocol.Glob.compile(pattern)
    max_queue_size = Keyword.get(opts, :max_queue_size, @default_max_queue_size)
    on_resync = Keyword.get(opts, :on_resync)

    {:ok, worker_pid} =
      Dust.CallbackWorker.start(
        callback: callback,
        ref: ref,
        max_queue_size: max_queue_size,
        on_resync: on_resync
      )

    :ets.insert(table, {store, compiled, pattern, worker_pid, ref, max_queue_size, on_resync})
    ref
  end

  def unregister(table, ref) do
    # Find the worker pid before deleting so we can stop it
    entries = :ets.match_object(table, {:_, :_, :_, :_, ref, :_, :_})

    Enum.each(entries, fn {_, _, _, worker_pid, _, _, _} ->
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    end)

    :ets.match_delete(table, {:_, :_, :_, :_, ref, :_, :_})
    :ok
  end

  @doc """
  Find all matching subscriptions for a store/path. Returns a list of
  `{worker_pid, ref, max_queue_size, on_resync}` tuples.
  """
  def match(table, store, path) do
    path_segments = String.split(path, ".")

    :ets.lookup(table, store)
    |> Enum.filter(fn {_store, compiled, _pattern, _pid, _ref, _max, _resync} ->
      Dust.Protocol.Glob.match?(compiled, path_segments)
    end)
    |> Enum.map(fn {_store, _compiled, _pattern, pid, ref, max, on_resync} ->
      {pid, ref, max, on_resync}
    end)
  end
end
