defmodule AdminWeb.StoresLive do
  use AdminWeb, :live_view

  import Ecto.Query
  alias Dust.Repo

  def mount(_params, _session, socket) do
    stores =
      from(s in Dust.Stores.Store,
        join: o in assoc(s, :organization),
        left_join: e in Dust.Sync.StoreEntry,
        on: e.store_id == s.id,
        left_join: op in Dust.Sync.StoreOp,
        on: op.store_id == s.id,
        group_by: [s.id, o.slug],
        select: %{
          id: s.id,
          name: s.name,
          status: s.status,
          org_slug: o.slug,
          entry_count: count(e.path, :distinct),
          op_count: count(op.id, :distinct),
          current_seq: max(op.store_seq),
          inserted_at: s.inserted_at
        },
        order_by: [desc: s.inserted_at]
      )
      |> Repo.all()

    {:ok, assign(socket, page_title: "Stores", stores: stores)}
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold text-gray-900 mb-6">Stores</h1>

    <div class="bg-white shadow rounded-lg overflow-hidden">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Organization
            </th>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Store
            </th>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Status
            </th>
            <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
              Entries
            </th>
            <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
              Ops
            </th>
            <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
              Current Seq
            </th>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Created
            </th>
          </tr>
        </thead>
        <tbody class="bg-white divide-y divide-gray-200">
          <tr :for={store <- @stores} class="hover:bg-gray-50">
            <td class="px-4 py-3 text-sm text-gray-600">{store.org_slug}</td>
            <td class="px-4 py-3 text-sm">
              <a href={~p"/stores/#{store.id}"} class="text-blue-600 hover:text-blue-800 font-medium">
                {store.name}
              </a>
            </td>
            <td class="px-4 py-3 text-sm">
              <span class={[
                "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                status_badge_class(store.status)
              ]}>
                {store.status}
              </span>
            </td>
            <td class="px-4 py-3 text-sm text-gray-600 text-right">{store.entry_count}</td>
            <td class="px-4 py-3 text-sm text-gray-600 text-right">{store.op_count}</td>
            <td class="px-4 py-3 text-sm text-gray-600 text-right">{store.current_seq || 0}</td>
            <td class="px-4 py-3 text-sm text-gray-500">
              {Calendar.strftime(store.inserted_at, "%Y-%m-%d %H:%M")}
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@stores == []} class="p-8 text-center text-gray-500">
        No stores found.
      </div>
    </div>
    """
  end

  defp status_badge_class(:active), do: "bg-green-100 text-green-800"
  defp status_badge_class(:archived), do: "bg-gray-100 text-gray-800"
  defp status_badge_class(_), do: "bg-gray-100 text-gray-800"
end
