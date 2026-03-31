defmodule DustWeb.SettingsController do
  use DustWeb, :controller

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    org = scope.organization
    memberships = Dust.Accounts.list_organization_members(org)

    conn
    |> assign(:page_title, "Settings")
    |> render_inertia("Settings/Index", %{
      organization: %{
        id: org.id,
        name: org.name,
        slug: org.slug,
        inserted_at: org.inserted_at
      },
      members: serialize_members(memberships)
    })
  end

  defp serialize_members(memberships) do
    Enum.map(memberships, fn m ->
      %{
        id: m.id,
        email: m.user.email,
        name: user_display_name(m.user),
        role: m.role,
        inserted_at: m.inserted_at
      }
    end)
  end

  defp user_display_name(user) do
    case {user.first_name, user.last_name} do
      {nil, nil} -> nil
      {first, nil} -> first
      {nil, last} -> last
      {first, last} -> "#{first} #{last}"
    end
  end
end
