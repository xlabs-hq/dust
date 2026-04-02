defmodule DustWeb.StoreChannel do
  use Phoenix.Channel

  alias Dust.{Stores, Sync, Files}
  alias Dust.Sync.{Rollback, ValueCodec}

  @valid_ops %{
    "set" => :set,
    "delete" => :delete,
    "merge" => :merge,
    "increment" => :increment,
    "add" => :add,
    "remove" => :remove,
    "put_file" => :put_file
  }

  @impl true
  def join("store:" <> store_ref, %{"last_store_seq" => last_seq}, socket) do
    store_token = socket.assigns.store_token

    # Resolve store by full name (contains "/") or by UUID
    with {:ok, store} <- resolve_store(store_ref),
         true <- store_token.store_id == store.id and Stores.StoreToken.can_read?(store_token) do
      send(self(), {:catch_up, last_seq})

      current_seq = Sync.current_seq(store.id)
      socket = assign(socket, :store_id, store.id)

      {:ok, %{store_seq: current_seq}, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("write", params, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      case Map.get(@valid_ops, params["op"]) do
        nil ->
          {:reply, {:error, %{reason: "invalid op"}}, socket}

        op ->
          with {:ok, _} <- validate_path(params["path"]),
               :ok <- validate_merge_value(op, params["value"]) do
            op_attrs = %{
              op: op,
              path: params["path"],
              value: params["value"],
              device_id: socket.assigns.device_id,
              client_op_id: params["client_op_id"]
            }

            case Sync.write(socket.assigns.store_id, op_attrs) do
              {:ok, db_op} ->
                broadcast!(socket, "event", format_event(db_op))
                {:reply, {:ok, %{store_seq: db_op.store_seq}}, socket}

              {:error, reason} ->
                {:reply, {:error, %{reason: inspect(reason)}}, socket}
            end
          else
            {:error, reason} ->
              {:reply, {:error, %{reason: to_string(reason)}}, socket}
          end
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_in(
        "put_file",
        %{
          "path" => path,
          "content" => base64_content,
          "client_op_id" => client_op_id
        } = params,
        socket
      ) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      with {:ok, _} <- validate_path(path),
           {:ok, content} <- Base.decode64(base64_content) do
        filename = params["filename"]
        content_type = params["content_type"] || "application/octet-stream"

        {:ok, ref} = Files.upload(content, filename: filename, content_type: content_type)

        op_attrs = %{
          op: :put_file,
          path: path,
          value: ref,
          device_id: socket.assigns.device_id,
          client_op_id: client_op_id
        }

        case Sync.write(socket.assigns.store_id, op_attrs) do
          {:ok, db_op} ->
            broadcast!(socket, "event", format_event(db_op))
            {:reply, {:ok, %{store_seq: db_op.store_seq, hash: ref["hash"]}}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end
      else
        :error ->
          {:reply, {:error, %{reason: "invalid_base64"}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_in("rollback", %{"path" => path, "to_seq" => to_seq}, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      case Rollback.rollback_path(socket.assigns.store_id, path, to_seq) do
        {:ok, :noop} ->
          {:reply, {:ok, %{store_seq: Sync.current_seq(socket.assigns.store_id), noop: true}},
           socket}

        {:ok, op} ->
          broadcast!(socket, "event", format_event(op))
          {:reply, {:ok, %{store_seq: op.store_seq}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  def handle_in("rollback", %{"to_seq" => to_seq}, socket) do
    store_token = socket.assigns.store_token

    if Stores.StoreToken.can_write?(store_token) do
      case Rollback.rollback_store(socket.assigns.store_id, to_seq) do
        {:ok, count} ->
          {:reply, {:ok, %{ops_written: count}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_info({:catch_up, last_seq}, socket) do
    ops = Sync.get_ops_since(socket.assigns.store_id, last_seq)

    Enum.each(ops, fn op ->
      push(socket, "event", format_event(op))
    end)

    # If we got a full batch, there may be more ops to send
    if length(ops) >= 1000 do
      last_op = List.last(ops)
      send(self(), {:catch_up, last_op.store_seq})
    end

    {:noreply, socket}
  end

  defp format_event(op) do
    %{
      store_seq: op.store_seq,
      op: op.op,
      path: op.path,
      value: ValueCodec.unwrap(op.value),
      device_id: op.device_id,
      client_op_id: op.client_op_id
    }
  end

  # If the store_ref contains "/", it's a full name like "org/store".
  # Otherwise, treat it as a UUID.
  defp resolve_store(store_ref) do
    if String.contains?(store_ref, "/") do
      case Stores.get_store_by_full_name(store_ref) do
        nil -> {:error, :not_found}
        store -> {:ok, store}
      end
    else
      try do
        {:ok, Stores.get_store!(store_ref)}
      rescue
        Ecto.NoResultsError -> {:error, :not_found}
      end
    end
  end

  defp validate_path(nil), do: {:error, :missing_path}
  defp validate_path(path) when is_binary(path), do: DustProtocol.Path.parse(path)
  defp validate_path(_), do: {:error, :invalid_path}

  defp validate_merge_value(:merge, value) when is_map(value), do: :ok
  defp validate_merge_value(:merge, _), do: {:error, :merge_requires_map_value}
  defp validate_merge_value(:increment, value) when is_number(value), do: :ok
  defp validate_merge_value(:increment, _), do: {:error, :increment_requires_number_value}
  defp validate_merge_value(:add, nil), do: {:error, :add_requires_value}
  defp validate_merge_value(:add, _), do: :ok
  defp validate_merge_value(:remove, nil), do: {:error, :remove_requires_value}
  defp validate_merge_value(:remove, _), do: :ok
  defp validate_merge_value(_, _), do: :ok
end
