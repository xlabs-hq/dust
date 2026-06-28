defmodule AdminWeb.UsersLive do
  use AdminWeb, :live_view

  alias Dust.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Users", users: Accounts.list_users())}
  end

  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-bold text-gray-900 mb-6">Users</h1>

    <div class="bg-white shadow rounded-lg overflow-hidden">
      <table class="min-w-full divide-y divide-gray-200">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Email
            </th>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Name
            </th>
            <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
              Orgs
            </th>
            <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Created
            </th>
          </tr>
        </thead>
        <tbody class="bg-white divide-y divide-gray-200">
          <tr :for={user <- @users} class="hover:bg-gray-50">
            <td class="px-4 py-3 text-sm">
              <a
                href={~p"/users/#{user.id}"}
                class="text-blue-600 hover:text-blue-800 font-medium"
              >
                {user.email}
              </a>
            </td>
            <td class="px-4 py-3 text-sm text-gray-600">{full_name(user)}</td>
            <td class="px-4 py-3 text-sm text-gray-600 text-right">{user.org_count}</td>
            <td class="px-4 py-3 text-sm text-gray-500">
              {Calendar.strftime(user.inserted_at, "%Y-%m-%d %H:%M")}
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@users == []} class="p-8 text-center text-gray-500">
        No users found.
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
end
