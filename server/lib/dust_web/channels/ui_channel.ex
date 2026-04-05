defmodule DustWeb.UIChannel do
  @moduledoc """
  Read-only channel for the browser UI.

  Subscribes to PubSub topics and forwards change notifications to the client.
  The client uses these to trigger Inertia partial reloads.
  """
  use Phoenix.Channel

  alias Dust.Stores

  @impl true
  def join("ui:store:" <> store_ref, _params, socket) do
    case resolve_store(store_ref) do
      {:ok, store} ->
        # Subscribe to the same PubSub topic the StoreChannel broadcasts on
        Phoenix.PubSub.subscribe(Dust.PubSub, "store:#{store_ref}")

        {:ok, assign(socket, :store_id, store.id)}

      _ ->
        {:error, %{reason: "not_found"}}
    end
  end

  def join("ui:org:" <> org_slug, _params, socket) do
    Phoenix.PubSub.subscribe(Dust.PubSub, "org_stores:#{org_slug}")
    {:ok, socket}
  end

  # Forward store channel broadcasts to the UI client
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "event"}, socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "snapshot"}, socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end

  # Org-level store change notifications
  def handle_info({:store_changed, _store_id}, socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp resolve_store(store_ref) do
    if String.contains?(store_ref, "/") do
      case Stores.get_store_by_full_name(store_ref) do
        nil -> {:error, :not_found}
        store -> {:ok, store}
      end
    else
      case Dust.Repo.get(Stores.Store, store_ref) do
        nil -> {:error, :not_found}
        store -> {:ok, store}
      end
    end
  end
end
