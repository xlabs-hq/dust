defmodule AdminWeb.OrgsLive do
  use AdminWeb, :live_view

  alias Dust.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Organizations", orgs: Accounts.list_organizations())}
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold text-gray-900 mb-6">Organizations</h1>

    <div class="bg-white shadow rounded-lg overflow-hidden">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Organization
            </th>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Plan
            </th>
            <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
              Members
            </th>
            <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
              Stores
            </th>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Created
            </th>
          </tr>
        </thead>
        <tbody class="bg-white divide-y divide-gray-200">
          <tr :for={org <- @orgs} class="hover:bg-gray-50">
            <td class="px-4 py-3 text-sm">
              <a
                href={~p"/orgs/#{org.id}"}
                class="text-blue-600 hover:text-blue-800 font-medium"
              >
                {org.slug}
              </a>
              <span :if={org.name != org.slug} class="text-gray-400 ml-1">({org.name})</span>
            </td>
            <td class="px-4 py-3 text-sm">
              <span class={[
                "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                plan_badge_class(org.plan)
              ]}>
                {org.plan}
              </span>
            </td>
            <td class="px-4 py-3 text-sm text-gray-600 text-right">{org.member_count}</td>
            <td class="px-4 py-3 text-sm text-gray-600 text-right">{org.store_count}</td>
            <td class="px-4 py-3 text-sm text-gray-500">
              {Calendar.strftime(org.inserted_at, "%Y-%m-%d %H:%M")}
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@orgs == []} class="p-8 text-center text-gray-500">
        No organizations found.
      </div>
    </div>
    """
  end

  defp plan_badge_class("free"), do: "bg-gray-100 text-gray-800"
  defp plan_badge_class("pro"), do: "bg-blue-100 text-blue-800"
  defp plan_badge_class("team"), do: "bg-purple-100 text-purple-800"
  defp plan_badge_class(_), do: "bg-gray-100 text-gray-800"
end
