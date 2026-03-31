defmodule Dust.SubscriberRegistrar do
  @moduledoc """
  One-off GenServer that starts last in the supervision tree and registers
  all declared `Dust.Subscriber` modules with their respective SyncEngines.

  This exists because subscriber registration needs the SyncEngines to be
  running, but the Supervisor hasn't started its children yet during `init/1`.
  By placing the registrar last in the children list, we guarantee all
  SyncEngines are up before registration runs.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    subscribers = Keyword.get(opts, :subscribers, [])

    Enum.each(subscribers, fn subscriber_module ->
      subscriber_module.__dust_register__()
    end)

    # We don't need to stay alive — registration is done.
    :ignore
  end
end
