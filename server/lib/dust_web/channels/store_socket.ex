defmodule DustWeb.StoreSocket do
  use Phoenix.Socket

  channel "store:*", DustWeb.StoreChannel

  @impl true
  def connect(%{"token" => token, "device_id" => device_id} = params, socket, _connect_info) do
    capver = parse_capver(params["capver"])

    with {:ok, store_token} <- Dust.Stores.authenticate_token(token),
         :ok <- check_capver(capver) do
      Dust.Stores.ensure_device(device_id)

      socket =
        socket
        |> assign(:store_token, store_token)
        |> assign(:device_id, device_id)
        |> assign(:capver, capver)

      {:ok, socket}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "store_socket:#{socket.assigns.device_id}"

  defp parse_capver(nil), do: 1

  defp parse_capver(capver) when is_binary(capver) do
    case Integer.parse(capver) do
      {int, ""} -> int
      _ -> 1
    end
  end

  defp parse_capver(capver) when is_integer(capver), do: capver
  defp parse_capver(_), do: 1

  defp check_capver(capver) do
    if capver >= DustProtocol.min_capver(), do: :ok, else: {:error, :capver_too_low}
  end
end
