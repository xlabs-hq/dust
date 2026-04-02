defmodule AdminWeb.StoreDetailLive do
  use AdminWeb, :live_view

  import Ecto.Query
  alias Dust.Repo

  @entries_per_page 50
  @ops_per_page 50

  def mount(%{"id" => id}, _session, socket) do
    store =
      Dust.Stores.Store
      |> Repo.get!(id)
      |> Repo.preload(:organization)

    entries = load_entries(id, 0)
    ops = load_ops(id, 0)

    entry_count = store.entry_count
    op_count = store.op_count

    {:ok,
     assign(socket,
       page_title: "Store: #{store.name}",
       store: store,
       entries: entries,
       ops: ops,
       entry_count: entry_count,
       op_count: op_count,
       entries_page: 0,
       ops_page: 0,
       entries_per_page: @entries_per_page,
       ops_per_page: @ops_per_page
     )}
  end

  def handle_event("entries_next", _params, socket) do
    page = socket.assigns.entries_page + 1
    entries = load_entries(socket.assigns.store.id, page)

    if entries == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, entries: entries, entries_page: page)}
    end
  end

  def handle_event("entries_prev", _params, socket) do
    page = max(socket.assigns.entries_page - 1, 0)
    entries = load_entries(socket.assigns.store.id, page)
    {:noreply, assign(socket, entries: entries, entries_page: page)}
  end

  def handle_event("ops_next", _params, socket) do
    page = socket.assigns.ops_page + 1
    ops = load_ops(socket.assigns.store.id, page)

    if ops == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, ops: ops, ops_page: page)}
    end
  end

  def handle_event("ops_prev", _params, socket) do
    page = max(socket.assigns.ops_page - 1, 0)
    ops = load_ops(socket.assigns.store.id, page)
    {:noreply, assign(socket, ops: ops, ops_page: page)}
  end

  defp load_entries(store_id, page) do
    Dust.Sync.get_entries_page(store_id, limit: @entries_per_page, offset: page * @entries_per_page)
  end

  defp load_ops(store_id, page) do
    Dust.Sync.get_ops_page(store_id, limit: @ops_per_page, offset: page * @ops_per_page)
  end

  def render(assigns) do
    ~H"""
    <div class="mb-4">
      <a href={~p"/stores"} class="text-sm text-blue-600 hover:text-blue-800">
        &larr; Back to stores
      </a>
    </div>

    <div class="mb-6">
      <h1 class="text-2xl font-bold text-gray-900">
        {String.upcase(@store.organization.slug)} / {@store.name}
      </h1>
      <div class="mt-2 flex items-center space-x-4 text-sm text-gray-500">
        <span>Status: <span class="font-medium text-gray-700">{@store.status}</span></span>
        <span>Entries: <span class="font-medium text-gray-700">{@entry_count}</span></span>
        <span>Ops: <span class="font-medium text-gray-700">{@op_count}</span></span>
        <span>ID: <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">{@store.id}</code></span>
      </div>
    </div>

    <%!-- Entries table --%>
    <div class="mb-8">
      <h2 class="text-lg font-semibold text-gray-900 mb-3">
        Entries
        <span class="text-sm font-normal text-gray-500">
          (showing {@entries_page * @entries_per_page + 1}-{@entries_page * @entries_per_page +
            length(@entries)} of {@entry_count})
        </span>
      </h2>

      <div class="bg-white shadow rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Path</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Type</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Seq</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Value</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <tr :for={entry <- @entries} class="hover:bg-gray-50">
              <td class="px-4 py-2 text-sm font-mono text-gray-900">{entry.path}</td>
              <td class="px-4 py-2 text-sm text-gray-600">{entry.type}</td>
              <td class="px-4 py-2 text-sm text-gray-600 text-right">{entry.seq}</td>
              <td class="px-4 py-2 text-sm">
                <code class="text-xs bg-gray-50 p-1 rounded break-all block max-w-lg">
                  {Jason.encode!(entry.value)}
                </code>
              </td>
            </tr>
          </tbody>
        </table>

        <div :if={@entries == []} class="p-6 text-center text-gray-500">No entries.</div>

        <div class="px-4 py-3 bg-gray-50 flex justify-between items-center text-sm">
          <button
            phx-click="entries_prev"
            disabled={@entries_page == 0}
            class="px-3 py-1 bg-white border rounded text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Previous
          </button>
          <span class="text-gray-500">Page {@entries_page + 1}</span>
          <button
            phx-click="entries_next"
            disabled={length(@entries) < @entries_per_page}
            class="px-3 py-1 bg-white border rounded text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Next
          </button>
        </div>
      </div>
    </div>

    <%!-- Ops table --%>
    <div class="mb-8">
      <h2 class="text-lg font-semibold text-gray-900 mb-3">
        Ops
        <span class="text-sm font-normal text-gray-500">
          (showing {@ops_page * @ops_per_page + 1}-{@ops_page * @ops_per_page + length(@ops)} of {@op_count})
        </span>
      </h2>

      <div class="bg-white shadow rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Seq</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Op</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Path</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Type</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Device</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Value</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Time</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <tr :for={op <- @ops} class="hover:bg-gray-50">
              <td class="px-4 py-2 text-sm text-gray-600 text-right font-mono">{op.store_seq}</td>
              <td class="px-4 py-2 text-sm">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  op_badge(op.op)
                ]}>
                  {op.op}
                </span>
              </td>
              <td class="px-4 py-2 text-sm font-mono text-gray-900">{op.path}</td>
              <td class="px-4 py-2 text-sm text-gray-600">{op.type}</td>
              <td class="px-4 py-2 text-sm text-gray-500 font-mono text-xs">
                {truncate_device(op.device_id)}
              </td>
              <td class="px-4 py-2 text-sm">
                <code :if={op.value} class="text-xs bg-gray-50 p-1 rounded break-all block max-w-xs">
                  {Jason.encode!(op.value)}
                </code>
              </td>
              <td class="px-4 py-2 text-sm text-gray-500">
                {Calendar.strftime(op.inserted_at, "%Y-%m-%d %H:%M:%S")}
              </td>
            </tr>
          </tbody>
        </table>

        <div :if={@ops == []} class="p-6 text-center text-gray-500">No ops.</div>

        <div class="px-4 py-3 bg-gray-50 flex justify-between items-center text-sm">
          <button
            phx-click="ops_prev"
            disabled={@ops_page == 0}
            class="px-3 py-1 bg-white border rounded text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Previous
          </button>
          <span class="text-gray-500">Page {@ops_page + 1}</span>
          <button
            phx-click="ops_next"
            disabled={length(@ops) < @ops_per_page}
            class="px-3 py-1 bg-white border rounded text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Next
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp op_badge(:set), do: "bg-blue-100 text-blue-800"
  defp op_badge(:delete), do: "bg-red-100 text-red-800"
  defp op_badge(:merge), do: "bg-purple-100 text-purple-800"
  defp op_badge(:increment), do: "bg-yellow-100 text-yellow-800"
  defp op_badge(:add), do: "bg-green-100 text-green-800"
  defp op_badge(:remove), do: "bg-orange-100 text-orange-800"
  defp op_badge(:put_file), do: "bg-indigo-100 text-indigo-800"
  defp op_badge(_), do: "bg-gray-100 text-gray-800"

  defp truncate_device(nil), do: "-"
  defp truncate_device(id) when byte_size(id) > 12, do: String.slice(id, 0, 12) <> "..."
  defp truncate_device(id), do: id
end
