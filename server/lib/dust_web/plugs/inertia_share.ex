defmodule DustWeb.Plugs.InertiaShare do
  @moduledoc """
  Assigns shared Inertia props available to all pages:
  current_user, current_organization, user_organizations, flash.
  """
  import Inertia.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    scope = conn.assigns[:current_scope]

    conn
    |> assign_prop(:current_user, serialize_user(scope))
    |> assign_prop(:current_organization, serialize_organization(scope))
    |> assign_prop(:user_organizations, serialize_user_organizations(scope))
    |> assign_prop(:socket_token, build_socket_token(scope))
    |> assign_prop(:flash, %{
      info: Phoenix.Flash.get(conn.assigns.flash, :info),
      error: Phoenix.Flash.get(conn.assigns.flash, :error)
    })
  end

  defp serialize_user(nil), do: nil
  defp serialize_user(%{user: nil}), do: nil

  defp serialize_user(%{user: user}) do
    %{
      id: user.id,
      email: user.email,
      name: user_display_name(user)
    }
  end

  defp serialize_organization(nil), do: nil
  defp serialize_organization(%{organization: nil}), do: nil

  defp serialize_organization(%{organization: org}) do
    %{
      id: org.id,
      name: org.name,
      slug: org.slug
    }
  end

  defp serialize_user_organizations(nil), do: []
  defp serialize_user_organizations(%{user: nil}), do: []

  defp serialize_user_organizations(%{user: user}) do
    if Ecto.assoc_loaded?(user.organizations) do
      Enum.map(user.organizations, fn org ->
        %{
          id: org.id,
          name: org.name,
          slug: org.slug
        }
      end)
    else
      []
    end
  end

  defp build_socket_token(nil), do: nil
  defp build_socket_token(%{user: nil}), do: nil
  defp build_socket_token(%{organization: nil}), do: nil

  defp build_socket_token(%{user: user, organization: org}) do
    DustWeb.UISocket.generate_token(user.id, org.id)
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
