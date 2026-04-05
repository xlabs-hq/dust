defmodule DustWeb.UISocket do
  @moduledoc """
  Socket for the browser UI. Authenticates via Phoenix.Token.
  Used by React/Inertia pages to receive real-time PubSub notifications.
  """
  use Phoenix.Socket

  channel "ui:store:*", DustWeb.UIChannel
  channel "ui:org:*", DustWeb.UIChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Phoenix.Token.verify(DustWeb.Endpoint, "ui socket", token, max_age: 86_400) do
      {:ok, %{"user_id" => user_id, "organization_id" => org_id}} ->
        socket =
          socket
          |> assign(:user_id, user_id)
          |> assign(:organization_id, org_id)

        {:ok, socket}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "ui_socket:#{socket.assigns.user_id}"

  @doc "Generate a socket token for the given user and organization."
  def generate_token(user_id, organization_id) do
    Phoenix.Token.sign(DustWeb.Endpoint, "ui socket", %{
      "user_id" => user_id,
      "organization_id" => organization_id
    })
  end
end
