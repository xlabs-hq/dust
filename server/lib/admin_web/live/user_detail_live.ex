defmodule AdminWeb.UserDetailLive do
  use AdminWeb, :live_view

  alias Dust.Accounts

  def mount(%{"id" => id}, _session, socket) do
    user = Accounts.get_user!(id)

    {:ok,
     assign(socket,
       page_title: "User: #{user.email}",
       user: user,
       memberships: Accounts.list_user_memberships(user)
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="mb-4">
      <a href={~p"/users"} class="text-sm text-blue-600 hover:text-blue-800">
        &larr; Back to users
      </a>
    </div>

    <div class="mb-6">
      <h1 class="text-2xl font-bold text-gray-900">{@user.email}</h1>
      <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-gray-500">
        <span>Name: <span class="font-medium text-gray-700">{full_name(@user)}</span></span>
        <span>ID: <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">{@user.id}</code></span>
        <span :if={@user.workos_id}>
          WorkOS: <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">{@user.workos_id}</code>
        </span>
      </div>
    </div>

    <div class="mb-8">
      <h2 class="text-lg font-semibold text-gray-900 mb-3">
        Organizations <span class="text-sm font-normal text-gray-500">({length(@memberships)})</span>
      </h2>
      <div class="bg-white shadow rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Organization
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Plan</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Role</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <tr :for={membership <- @memberships} class="hover:bg-gray-50">
              <td class="px-4 py-2 text-sm">
                <a
                  href={~p"/orgs/#{membership.organization.id}"}
                  class="text-blue-600 hover:text-blue-800 font-medium"
                >
                  {membership.organization.slug}
                </a>
              </td>
              <td class="px-4 py-2 text-sm">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  plan_badge_class(membership.organization.plan)
                ]}>
                  {membership.organization.plan}
                </span>
              </td>
              <td class="px-4 py-2 text-sm text-gray-600">{membership.role}</td>
            </tr>
          </tbody>
        </table>
        <div :if={@memberships == []} class="p-6 text-center text-gray-500">
          Not a member of any organization.
        </div>
      </div>
    </div>
    """
  end

  defp full_name(%{first_name: nil, last_name: nil}), do: "-"

  defp full_name(user) do
    [user.first_name, user.last_name]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> "-"
      name -> name
    end
  end

  defp plan_badge_class("free"), do: "bg-gray-100 text-gray-800"
  defp plan_badge_class("pro"), do: "bg-blue-100 text-blue-800"
  defp plan_badge_class("team"), do: "bg-purple-100 text-purple-800"
  defp plan_badge_class(_), do: "bg-gray-100 text-gray-800"
end
