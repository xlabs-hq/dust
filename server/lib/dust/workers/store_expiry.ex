defmodule Dust.Workers.StoreExpiry do
  use Oban.Worker, queue: :default

  import Ecto.Query
  require Logger

  alias Dust.Repo
  alias Dust.Stores.Store
  alias Dust.Sync.Writer

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    expired_stores =
      from(s in Store,
        where: s.status == :active and not is_nil(s.expires_at) and s.expires_at < ^now,
        preload: [:organization]
      )
      |> Repo.all()

    Enum.each(expired_stores, fn store ->
      Logger.info("Archiving expired store #{store.id}")

      # Archive the store
      from(s in Store, where: s.id == ^store.id)
      |> Repo.update_all(set: [status: :archived])

      # Stop the Writer if running
      Writer.stop(store.id)

      # Disconnect any connected clients — broadcast to both topic formats
      DustWeb.Endpoint.broadcast("store:#{store.id}", "phx_close", %{})

      DustWeb.Endpoint.broadcast(
        "store:#{store.organization.slug}/#{store.name}",
        "phx_close",
        %{}
      )
    end)

    :ok
  end
end
