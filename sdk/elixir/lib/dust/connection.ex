defmodule Dust.Connection do
  @moduledoc """
  WebSocket client that connects to the Dust server via Phoenix Channels.

  Uses Slipstream to manage the connection lifecycle, heartbeats,
  reconnection, and ref tracking. Joins one channel per store using
  topic "store:{store_name}" and forwards server events to SyncEngines.
  """
  use Slipstream

  require Logger

  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl Slipstream
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    token = Keyword.fetch!(opts, :token)
    device_id = Keyword.get(opts, :device_id, generate_device_id())
    stores = Keyword.fetch!(opts, :stores)
    test_mode? = Keyword.get(opts, :test_mode?, false)

    socket =
      new_socket()
      |> assign(:token, token)
      |> assign(:device_id, device_id)
      |> assign(:stores, stores)
      |> assign(:joined_stores, MapSet.new())
      |> assign(:outbox, %{})

    if test_mode? do
      {:ok, socket}
    else
      # Build the URI with connection params embedded in the query string.
      # Phoenix expects params as query string params on the websocket URL.
      uri =
        url
        |> URI.parse()
        |> append_path("/websocket")
        |> Map.put(
          :query,
          URI.encode_query(%{
            "token" => token,
            "device_id" => device_id,
            "capver" => "1",
            "vsn" => "2.0.0"
          })
        )
        |> URI.to_string()

      case connect(socket, uri: uri) do
        {:ok, socket} -> {:ok, socket}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("[Dust.Connection] Connected to server")
    stores = socket.assigns.stores

    # Join each store's channel topic
    socket =
      Enum.reduce(stores, socket, fn store_name, sock ->
        topic = "store:#{store_name}"
        last_seq = get_last_store_seq(store_name)
        join(sock, topic, %{"last_store_seq" => last_seq})
      end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join("store:" <> store_name, reply, socket) do
    store_seq = reply["store_seq"] || Map.get(reply, :store_seq, 0)
    Logger.info("[Dust.Connection] Joined store:#{store_name}, seq=#{store_seq}")

    joined = MapSet.put(socket.assigns.joined_stores, store_name)
    socket = assign(socket, :joined_stores, joined)

    # Flush any queued writes for this store
    socket = flush_outbox(socket, store_name)

    # Update the SyncEngine's status to :connected (also triggers resend of pending_ops)
    Dust.SyncEngine.set_status(store_name, :connected)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_message("store:" <> store_name, "event", payload, socket) do
    Dust.SyncEngine.handle_server_event(store_name, payload)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("[Dust.Connection] Disconnected: #{inspect(reason)}")

    # Update all joined stores to :reconnecting
    Enum.each(socket.assigns.joined_stores, fn store_name ->
      Dust.SyncEngine.set_status(store_name, :reconnecting)
    end)

    socket = assign(socket, :joined_stores, MapSet.new())

    # Use Slipstream's built-in reconnect with backoff
    case reconnect(socket) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :no_config} ->
        # Test mode or not yet configured -- just stay alive
        {:ok, socket}

      {:error, reason} ->
        {:stop, reason, socket}
    end
  end

  @impl Slipstream
  def handle_topic_close("store:" <> store_name = topic, reason, socket) do
    Logger.warning("[Dust.Connection] Topic #{topic} closed: #{inspect(reason)}")

    joined = MapSet.delete(socket.assigns.joined_stores, store_name)
    socket = assign(socket, :joined_stores, joined)
    Dust.SyncEngine.set_status(store_name, :reconnecting)

    # Rejoin with backoff
    case rejoin(socket, topic) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_info({:send_write, store_name, op_attrs}, socket) do
    topic = "store:#{store_name}"

    params = %{
      "op" => to_string(op_attrs.op),
      "path" => op_attrs.path,
      "value" => op_attrs[:value],
      "client_op_id" => op_attrs.client_op_id
    }

    if MapSet.member?(socket.assigns.joined_stores, store_name) do
      push(socket, topic, "write", params)
      {:noreply, socket}
    else
      # Not yet joined — queue the write for flush after join
      outbox = Map.get(socket.assigns, :outbox, %{})
      store_queue = Map.get(outbox, store_name, :queue.new())
      store_queue = :queue.in(params, store_queue)
      outbox = Map.put(outbox, store_name, store_queue)
      {:noreply, assign(socket, :outbox, outbox)}
    end
  end

  # -- Private helpers --

  defp flush_outbox(socket, store_name) do
    outbox = Map.get(socket.assigns, :outbox, %{})
    store_queue = Map.get(outbox, store_name, :queue.new())
    topic = "store:#{store_name}"

    socket =
      Enum.reduce(:queue.to_list(store_queue), socket, fn params, sock ->
        push(sock, topic, "write", params)
        sock
      end)

    outbox = Map.delete(outbox, store_name)
    assign(socket, :outbox, outbox)
  end

  defp get_last_store_seq(store_name) do
    case Registry.lookup(Dust.SyncEngineRegistry, store_name) do
      [{pid, _}] ->
        status = GenServer.call(pid, :status)
        status.last_store_seq

      [] ->
        0
    end
  end

  defp generate_device_id do
    "dev_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp append_path(%URI{path: nil} = uri, suffix), do: %{uri | path: suffix}
  defp append_path(%URI{path: path} = uri, suffix), do: %{uri | path: path <> suffix}
end
