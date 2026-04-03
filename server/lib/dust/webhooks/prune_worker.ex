defmodule Dust.Webhooks.PruneWorker do
  use Oban.Worker, queue: :default

  import Ecto.Query

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.utc_now() |> DateTime.add(-7, :day)

    Dust.Repo.delete_all(
      from(d in Dust.Webhooks.DeliveryLog, where: d.attempted_at < ^cutoff)
    )

    :ok
  end
end
