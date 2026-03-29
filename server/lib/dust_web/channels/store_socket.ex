defmodule DustWeb.StoreSocket do
  use Phoenix.Socket

  channel "store:*", DustWeb.StoreChannel

  @impl true
  def connect(%{"token" => token, "device_id" => device_id, "capver" => capver}, socket, _connect_info) do
    case Dust.Stores.authenticate_token(token) do
      {:ok, store_token} ->
        Dust.Stores.ensure_device(device_id)

        socket =
          socket
          |> assign(:store_token, store_token)
          |> assign(:device_id, device_id)
          |> assign(:capver, capver)

        {:ok, socket}

      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "store_socket:#{socket.assigns.device_id}"
end
