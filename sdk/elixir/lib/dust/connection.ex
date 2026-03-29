defmodule Dust.Connection do
  @moduledoc """
  WebSocket client that connects to the Dust server.
  Handles hello handshake, store joins, catch-up replay,
  and forwarding writes from SyncEngines.

  Full implementation wired up during integration testing (Task 11).
  """
  use GenServer

  defstruct [:url, :token, :device_id, :stores, :status]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      url: Keyword.fetch!(opts, :url),
      token: Keyword.fetch!(opts, :token),
      device_id: Keyword.get(opts, :device_id, generate_device_id()),
      stores: Keyword.fetch!(opts, :stores),
      status: :disconnected
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:send_write, _op_attrs}, state) do
    # TODO: send via WebSocket in integration task
    {:noreply, state}
  end

  defp generate_device_id do
    "dev_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
