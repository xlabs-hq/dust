defmodule AdminWeb.DashboardLive do
  use AdminWeb, :live_view

  alias Dust.Repo

  def mount(_params, _session, socket) do
    stats = %{
      users: Repo.aggregate(Dust.Accounts.User, :count),
      organizations: Repo.aggregate(Dust.Accounts.Organization, :count),
      stores: Repo.aggregate(Dust.Stores.Store, :count),
      ops: Repo.aggregate(Dust.Sync.StoreOp, :count),
      entries: Repo.aggregate(Dust.Sync.StoreEntry, :count)
    }

    {:ok, assign(socket, page_title: "Dashboard", stats: stats)}
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold text-gray-900 mb-6">Dashboard</h1>

    <div class="grid grid-cols-1 md:grid-cols-3 lg:grid-cols-5 gap-4 mb-8">
      <.stat_card label="Users" value={@stats.users} />
      <.stat_card label="Organizations" value={@stats.organizations} />
      <.stat_card label="Stores" value={@stats.stores} />
      <.stat_card label="Ops" value={@stats.ops} />
      <.stat_card label="Entries" value={@stats.entries} />
    </div>
    """
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-5">
      <dt class="text-sm font-medium text-gray-500 truncate">{@label}</dt>
      <dd class="mt-1 text-3xl font-semibold text-gray-900">
        {format_number(@value)}
      </dd>
    </div>
    """
  end
end
