defmodule DustWeb.StoreChannel do
  use Phoenix.Channel

  alias Dust.{Stores, Sync}

  @impl true
  def join("store:" <> store_id, %{"last_store_seq" => last_seq}, socket) do
    store_token = socket.assigns.store_token

    if store_token.store_id == store_id and Stores.StoreToken.can_read?(store_token) do
      send(self(), {:catch_up, last_seq})

      current_seq = Sync.current_seq(store_id)
      socket = assign(socket, :store_id, store_id)

      {:ok, %{store_seq: current_seq}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("write", params, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      op_attrs = %{
        op: String.to_existing_atom(params["op"]),
        path: params["path"],
        value: params["value"],
        device_id: socket.assigns.device_id,
        client_op_id: params["client_op_id"]
      }

      case Sync.write(socket.assigns.store_id, op_attrs) do
        {:ok, op} ->
          broadcast!(socket, "event", %{
            store_seq: op.store_seq,
            op: op.op,
            path: op.path,
            value: params["value"],
            device_id: socket.assigns.device_id,
            client_op_id: params["client_op_id"]
          })

          {:reply, {:ok, %{store_seq: op.store_seq}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: inspect(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_info({:catch_up, last_seq}, socket) do
    ops = Sync.get_ops_since(socket.assigns.store_id, last_seq)

    Enum.each(ops, fn op ->
      push(socket, "event", %{
        store_seq: op.store_seq,
        op: op.op,
        path: op.path,
        value: op.value,
        device_id: op.device_id,
        client_op_id: op.client_op_id
      })
    end)

    {:noreply, socket}
  end
end
