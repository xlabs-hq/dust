defmodule AdminWeb.OpsLive do
  use AdminWeb, :live_view

  import Ecto.Query
  alias Dust.Repo

  @per_page 50

  def mount(_params, _session, socket) do
    ops = load_ops(%{}, 0)

    stores =
      from(s in Dust.Stores.Store,
        join: o in assoc(s, :organization),
        select: {s.id, fragment("? || '/' || ?", o.slug, s.name)},
        order_by: [asc: o.slug, asc: s.name]
      )
      |> Repo.all()

    {:ok,
     assign(socket,
       page_title: "Ops",
       ops: ops,
       stores: stores,
       filters: %{},
       page: 0,
       per_page: @per_page
     )}
  end

  def handle_event("filter", params, socket) do
    filters =
      %{}
      |> maybe_put(:store_id, params["store_id"])
      |> maybe_put(:device_id, params["device_id"])
      |> maybe_put(:op, params["op"])

    ops = load_ops(filters, 0)
    {:noreply, assign(socket, ops: ops, filters: filters, page: 0)}
  end

  def handle_event("next_page", _params, socket) do
    page = socket.assigns.page + 1
    ops = load_ops(socket.assigns.filters, page)

    if ops == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, ops: ops, page: page)}
    end
  end

  def handle_event("prev_page", _params, socket) do
    page = max(socket.assigns.page - 1, 0)
    ops = load_ops(socket.assigns.filters, page)
    {:noreply, assign(socket, ops: ops, page: page)}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp load_ops(filters, page) do
    store_id = filters[:store_id]

    if store_id && store_id != "" do
      # Get store metadata for display
      store = Repo.get(Dust.Stores.Store, store_id) |> Repo.preload(:organization)

      audit_opts =
        [limit: @per_page, offset: page * @per_page]
        |> maybe_add_filter(:device_id, filters[:device_id])
        |> maybe_add_filter(:op, filters[:op])

      Dust.Sync.Audit.query_ops(store_id, audit_opts)
      |> Enum.map(fn op ->
        Map.merge(op, %{
          store_name: store && store.name,
          store_id: store_id,
          org_slug: store && store.organization.slug
        })
      end)
    else
      # No store selected — show empty (can't query all SQLite files efficiently)
      []
    end
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold text-gray-900 mb-6">Global Op Log</h1>

    <%!-- Filters --%>
    <form phx-change="filter" class="mb-6 flex flex-wrap gap-4 items-end">
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">Store</label>
        <select name="store_id" class="border border-gray-300 rounded px-3 py-1.5 text-sm bg-white">
          <option value="">All stores</option>
          <option :for={{id, label} <- @stores} value={id} selected={@filters[:store_id] == id}>
            {label}
          </option>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">Op type</label>
        <select name="op" class="border border-gray-300 rounded px-3 py-1.5 text-sm bg-white">
          <option value="">All</option>
          <option
            :for={op <- ~w(set delete merge increment add remove put_file)}
            value={op}
            selected={@filters[:op] == op}
          >
            {op}
          </option>
        </select>
      </div>

      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">Device ID</label>
        <input
          type="text"
          name="device_id"
          value={@filters[:device_id] || ""}
          placeholder="Filter by device..."
          class="border border-gray-300 rounded px-3 py-1.5 text-sm"
          phx-debounce="300"
        />
      </div>
    </form>

    <%!-- Table --%>
    <div class="bg-white shadow rounded-lg overflow-hidden">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Store</th>
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
            <td class="px-4 py-2 text-sm">
              <a href={~p"/stores/#{op.store_id}"} class="text-blue-600 hover:text-blue-800">
                {op.org_slug}/{op.store_name}
              </a>
            </td>
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
            <td class="px-4 py-2 text-sm text-gray-500 whitespace-nowrap">
              {Calendar.strftime(op.inserted_at, "%Y-%m-%d %H:%M:%S")}
            </td>
          </tr>
        </tbody>
      </table>

      <div
        :if={@ops == [] && (!@filters[:store_id] || @filters[:store_id] == "")}
        class="p-8 text-center text-gray-500"
      >
        Select a store to view ops.
      </div>
      <div
        :if={@ops == [] && @filters[:store_id] && @filters[:store_id] != ""}
        class="p-8 text-center text-gray-500"
      >
        No ops found.
      </div>

      <div class="px-4 py-3 bg-gray-50 flex justify-between items-center text-sm">
        <button
          phx-click="prev_page"
          disabled={@page == 0}
          class="px-3 py-1 bg-white border rounded text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          Previous
        </button>
        <span class="text-gray-500">Page {@page + 1}</span>
        <button
          phx-click="next_page"
          disabled={length(@ops) < @per_page}
          class="px-3 py-1 bg-white border rounded text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          Next
        </button>
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
