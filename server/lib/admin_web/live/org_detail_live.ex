defmodule AdminWeb.OrgDetailLive do
  use AdminWeb, :live_view

  alias Dust.Accounts
  alias Dust.Billing.Limits
  alias Dust.Stores

  def mount(%{"id" => id}, _session, socket) do
    org = Accounts.get_organization!(id)

    {:ok,
     socket
     |> assign(
       page_title: "Org: #{org.slug}",
       org: org,
       members: Accounts.list_organization_members(org),
       stores: Stores.list_stores(org),
       plan_names: Limits.plan_names(),
       pending_plan: nil,
       plan_notice: nil
     )
     |> assign_limits()}
  end

  def handle_event("select_plan", %{"plan" => plan}, socket) do
    pending = if plan == socket.assigns.org.plan, do: nil, else: plan
    {:noreply, assign(socket, pending_plan: pending, plan_notice: nil)}
  end

  def handle_event("cancel_plan", _params, socket) do
    {:noreply, assign(socket, pending_plan: nil)}
  end

  def handle_event("confirm_plan", _params, socket) do
    %{org: org, pending_plan: plan} = socket.assigns

    case Accounts.update_organization_plan(org, plan) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(
           org: updated,
           pending_plan: nil,
           plan_notice: "Plan changed to #{updated.plan}."
         )
         |> assign_limits()}

      {:error, _changeset} ->
        {:noreply,
         assign(socket, pending_plan: nil, plan_notice: "Could not change plan to #{plan}.")}
    end
  end

  defp assign_limits(socket) do
    assign(socket, limits: Limits.for_plan(socket.assigns.org.plan))
  end

  def render(assigns) do
    ~H"""
    <div class="mb-4">
      <a href={~p"/orgs"} class="text-sm text-blue-600 hover:text-blue-800">
        &larr; Back to organizations
      </a>
    </div>

    <div class="mb-6">
      <h1 class="text-2xl font-bold text-gray-900">{@org.slug}</h1>
      <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-gray-500">
        <span>Name: <span class="font-medium text-gray-700">{@org.name}</span></span>
        <span>ID: <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">{@org.id}</code></span>
        <span :if={@org.workos_organization_id}>
          WorkOS:
          <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">{@org.workos_organization_id}</code>
        </span>
      </div>
    </div>

    <%!-- Plan & limits --%>
    <div class="mb-8 bg-white shadow rounded-lg p-5">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold text-gray-900">Plan</h2>
        <span class={[
          "inline-flex items-center px-2.5 py-0.5 rounded text-sm font-medium",
          plan_badge_class(@org.plan)
        ]}>
          {@org.plan}
        </span>
      </div>

      <div
        :if={@plan_notice}
        id="plan-notice"
        class="mb-4 rounded bg-green-50 border border-green-200 text-green-800 text-sm px-3 py-2"
      >
        {@plan_notice}
      </div>

      <dl class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-5 text-sm">
        <div>
          <dt class="text-gray-500">Stores</dt>
          <dd class="font-medium text-gray-900">{format_limit(@limits.stores)}</dd>
        </div>
        <div>
          <dt class="text-gray-500">Keys / store</dt>
          <dd class="font-medium text-gray-900">{format_limit(@limits.keys_per_store)}</dd>
        </div>
        <div>
          <dt class="text-gray-500">File storage</dt>
          <dd class="font-medium text-gray-900">{format_bytes(@limits.file_storage_bytes)}</dd>
        </div>
        <div>
          <dt class="text-gray-500">Retention</dt>
          <dd class="font-medium text-gray-900">{@limits.retention_days} days</dd>
        </div>
      </dl>

      <div class="border-t border-gray-100 pt-4">
        <p class="text-sm text-gray-500 mb-2">Change plan</p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={plan <- @plan_names}
            type="button"
            phx-click="select_plan"
            phx-value-plan={plan}
            disabled={plan == @org.plan}
            class={[
              "px-3 py-1.5 rounded text-sm font-medium border",
              if(plan == @org.plan,
                do: "bg-gray-100 text-gray-400 border-gray-200 cursor-default",
                else: "bg-white text-gray-700 border-gray-300 hover:bg-gray-50"
              ),
              @pending_plan == plan && "ring-2 ring-blue-400"
            ]}
          >
            {plan}
          </button>
        </div>

        <div
          :if={@pending_plan}
          id="plan-confirm"
          class="mt-4 rounded border border-amber-300 bg-amber-50 px-4 py-3"
        >
          <p class="text-sm text-amber-900 mb-3">
            Change plan from <span class="font-semibold">{@org.plan}</span>
            to <span class="font-semibold">{@pending_plan}</span>?
          </p>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="confirm_plan"
              class="px-3 py-1.5 rounded text-sm font-medium bg-blue-600 text-white hover:bg-blue-700"
            >
              Confirm change to {@pending_plan}
            </button>
            <button
              type="button"
              phx-click="cancel_plan"
              class="px-3 py-1.5 rounded text-sm font-medium bg-white border border-gray-300 text-gray-700 hover:bg-gray-50"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>

    <%!-- Members --%>
    <div class="mb-8">
      <h2 class="text-lg font-semibold text-gray-900 mb-3">
        Members <span class="text-sm font-normal text-gray-500">({length(@members)})</span>
      </h2>
      <div class="bg-white shadow rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Email</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Name</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Role</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <tr :for={member <- @members} class="hover:bg-gray-50">
              <td class="px-4 py-2 text-sm">
                <a
                  href={~p"/users/#{member.user.id}"}
                  class="text-blue-600 hover:text-blue-800"
                >
                  {member.user.email}
                </a>
              </td>
              <td class="px-4 py-2 text-sm text-gray-600">{full_name(member.user)}</td>
              <td class="px-4 py-2 text-sm text-gray-600">{member.role}</td>
            </tr>
          </tbody>
        </table>
        <div :if={@members == []} class="p-6 text-center text-gray-500">No members.</div>
      </div>
    </div>

    <%!-- Stores --%>
    <div class="mb-8">
      <h2 class="text-lg font-semibold text-gray-900 mb-3">
        Stores <span class="text-sm font-normal text-gray-500">({length(@stores)})</span>
      </h2>
      <div class="bg-white shadow rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Store</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Status</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                Entries
              </th>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Ops</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200">
            <tr
              :for={store <- @stores}
              class="hover:bg-gray-50 cursor-pointer"
              phx-click={JS.navigate(~p"/stores/#{store.id}")}
            >
              <td class="px-4 py-2 text-sm">
                <a
                  href={~p"/stores/#{store.id}"}
                  class="text-blue-600 hover:text-blue-800 font-medium"
                >
                  {store.name}
                </a>
              </td>
              <td class="px-4 py-2 text-sm text-gray-600">{store.status}</td>
              <td class="px-4 py-2 text-sm text-gray-600 text-right">{store.entry_count}</td>
              <td class="px-4 py-2 text-sm text-gray-600 text-right">{store.op_count}</td>
            </tr>
          </tbody>
        </table>
        <div :if={@stores == []} class="p-6 text-center text-gray-500">No stores.</div>
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

  defp format_limit(:unlimited), do: "Unlimited"

  defp format_limit(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{div(bytes, 1_000_000_000)} GB"
      bytes >= 1_000_000 -> "#{div(bytes, 1_000_000)} MB"
      bytes >= 1_000 -> "#{div(bytes, 1_000)} KB"
      true -> "#{bytes} B"
    end
  end

  defp plan_badge_class("free"), do: "bg-gray-100 text-gray-800"
  defp plan_badge_class("pro"), do: "bg-blue-100 text-blue-800"
  defp plan_badge_class("team"), do: "bg-purple-100 text-purple-800"
  defp plan_badge_class(_), do: "bg-gray-100 text-gray-800"
end
