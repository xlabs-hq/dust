defmodule Dust.CallbackWorker do
  @moduledoc """
  Per-subscription worker process that receives events and calls the callback.

  Each subscription gets its own worker with a bounded mailbox. The SyncEngine
  checks `Process.info(pid, :message_queue_len)` before dispatching; if the
  queue exceeds `max_queue_size`, the subscription is dropped and the
  `on_resync` callback fires with `%{error: :resync_required}`.
  """

  use GenServer

  defstruct [:callback, :ref, :max_queue_size, :on_resync]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Start a worker without linking to the caller."
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc "Send an event to the worker. Called by the SyncEngine dispatcher."
  def dispatch(pid, event) do
    GenServer.cast(pid, {:event, event})
  end

  @doc "Return the current message queue length of the worker process."
  def queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      nil -> 0
    end
  end

  # Server

  @impl true
  def init(opts) do
    state = %__MODULE__{
      callback: Keyword.fetch!(opts, :callback),
      ref: Keyword.fetch!(opts, :ref),
      max_queue_size: Keyword.get(opts, :max_queue_size, 1000),
      on_resync: Keyword.get(opts, :on_resync)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    state.callback.(event)
    {:noreply, state}
  end
end
