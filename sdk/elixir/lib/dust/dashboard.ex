if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Dust.Dashboard do
    @moduledoc """
    LiveDashboard page for Dust SDK introspection.

    ## Setup

        live_dashboard "/dev/dashboard",
          additional_pages: [
            dust: Dust.Dashboard
          ]
    """

    use Phoenix.LiveDashboard.PageBuilder

    @impl true
    def menu_link(_, _) do
      {:ok, "Dust"}
    end

    @impl true
    def mount(_params, session, socket) do
      socket =
        socket
        |> assign(:connection_info, fetch_connection_info())
        |> assign(:stores, fetch_stores())
        |> assign(:selected_store, nil)
        |> assign(:entries, [])
        |> assign(:entries_cursor, nil)
        |> assign(:entries_filter, "")
        |> assign(:activity, [])
        |> assign(:nav, session["nav"] || :stores)

      {:ok, socket}
    end

    @impl true
    def handle_refresh(socket) do
      socket =
        socket
        |> assign(:connection_info, fetch_connection_info())
        |> assign(:stores, fetch_stores())

      socket =
        if store = socket.assigns.selected_store do
          assign(socket, :activity, fetch_activity(store))
        else
          socket
        end

      {:noreply, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <!-- Connection Bar -->
        <div style="display: flex; gap: 24px; align-items: center; margin-bottom: 16px; padding: 12px; background: #f8f9fa; border-radius: 6px;">
          <div>
            <strong>Status:</strong>
            <span style={"color: #{status_color(@connection_info.status)}"}>
              <%= @connection_info.status %>
            </span>
          </div>
          <div><strong>URL:</strong> <%= @connection_info.url || "—" %></div>
          <div><strong>Device:</strong> <code><%= @connection_info.device_id || "—" %></code></div>
          <div :if={@connection_info.uptime_seconds}>
            <strong>Uptime:</strong> <%= format_uptime(@connection_info.uptime_seconds) %>
          </div>
        </div>

        <!-- Stores Table -->
        <h3 style="margin-bottom: 8px;">Stores</h3>
        <table style="width: 100%; border-collapse: collapse; margin-bottom: 24px;">
          <thead>
            <tr style="border-bottom: 2px solid #dee2e6;">
              <th style="text-align: left; padding: 8px;">Store</th>
              <th style="text-align: right; padding: 8px;">Entries</th>
              <th style="text-align: right; padding: 8px;">Last Seq</th>
              <th style="text-align: right; padding: 8px;">Pending</th>
              <th style="text-align: center; padding: 8px;">Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={store <- @stores}
                style={"cursor: pointer; #{if @selected_store == store.store, do: "background: #e8f4fd;", else: ""}"}
                phx-click="select_store"
                phx-value-store={store.store}>
              <td style="padding: 8px;"><code><%= store.store %></code></td>
              <td style="text-align: right; padding: 8px;"><%= store.entry_count || "—" %></td>
              <td style="text-align: right; padding: 8px;"><%= store.last_store_seq %></td>
              <td style="text-align: right; padding: 8px;"><%= store.pending_ops %></td>
              <td style="text-align: center; padding: 8px;">
                <span style={"color: #{status_color(store.connection)}"}>
                  <%= store.connection %>
                </span>
              </td>
            </tr>
          </tbody>
        </table>

        <!-- Bottom panels (entries + activity) -->
        <div :if={@selected_store} style="display: grid; grid-template-columns: 1fr 1fr; gap: 24px;">
          <!-- Entries Browser -->
          <div>
            <h3 style="margin-bottom: 8px;">Entries — <code><%= @selected_store %></code></h3>
            <form phx-change="filter_entries" style="margin-bottom: 8px;">
              <input name="pattern" value={@entries_filter} placeholder="Filter by glob pattern..." style="width: 100%; padding: 6px; border: 1px solid #ced4da; border-radius: 4px;" />
            </form>
            <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
              <thead>
                <tr style="border-bottom: 1px solid #dee2e6;">
                  <th style="text-align: left; padding: 4px;">Path</th>
                  <th style="text-align: left; padding: 4px;">Value</th>
                  <th style="text-align: left; padding: 4px;">Type</th>
                  <th style="text-align: right; padding: 4px;">Seq</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{path, value, type, seq} <- @entries} style="border-bottom: 1px solid #f0f0f0;">
                  <td style="padding: 4px;"><code><%= path %></code></td>
                  <td style="padding: 4px; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                    <%= truncate_value(value) %>
                  </td>
                  <td style="padding: 4px;"><%= type %></td>
                  <td style="text-align: right; padding: 4px;"><%= seq %></td>
                </tr>
              </tbody>
            </table>
            <div :if={@entries_cursor} style="margin-top: 8px;">
              <button phx-click="next_page" style="padding: 4px 12px; border: 1px solid #ced4da; border-radius: 4px; background: white; cursor: pointer;">
                Next page →
              </button>
            </div>
          </div>

          <!-- Activity Feed -->
          <div>
            <h3 style="margin-bottom: 8px;">Activity</h3>
            <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
              <thead>
                <tr style="border-bottom: 1px solid #dee2e6;">
                  <th style="text-align: left; padding: 4px;">Time</th>
                  <th style="text-align: left; padding: 4px;">Path</th>
                  <th style="text-align: left; padding: 4px;">Op</th>
                  <th style="text-align: left; padding: 4px;">Source</th>
                  <th style="text-align: right; padding: 4px;">Seq</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @activity} style="border-bottom: 1px solid #f0f0f0;">
                  <td style="padding: 4px;"><%= format_time(entry.timestamp) %></td>
                  <td style="padding: 4px;"><code><%= entry.path %></code></td>
                  <td style="padding: 4px;"><%= entry.op %></td>
                  <td style="padding: 4px;"><%= entry.source %></td>
                  <td style="text-align: right; padding: 4px;"><%= entry.seq %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      """
    end

    @impl true
    def handle_event("select_store", %{"store" => store}, socket) do
      {entries, cursor} = browse_store(store, nil, "")

      socket =
        socket
        |> assign(:selected_store, store)
        |> assign(:entries, entries)
        |> assign(:entries_cursor, cursor)
        |> assign(:entries_filter, "")
        |> assign(:activity, fetch_activity(store))

      {:noreply, socket}
    end

    def handle_event("filter_entries", %{"pattern" => pattern}, socket) do
      store = socket.assigns.selected_store
      {entries, cursor} = browse_store(store, nil, pattern)

      socket =
        socket
        |> assign(:entries, entries)
        |> assign(:entries_cursor, cursor)
        |> assign(:entries_filter, pattern)

      {:noreply, socket}
    end

    def handle_event("next_page", _, socket) do
      store = socket.assigns.selected_store
      cursor = socket.assigns.entries_cursor
      pattern = socket.assigns.entries_filter
      {entries, next_cursor} = browse_store(store, cursor, pattern)

      socket =
        socket
        |> assign(:entries, entries)
        |> assign(:entries_cursor, next_cursor)

      {:noreply, socket}
    end

    # Data fetching

    defp fetch_connection_info do
      case GenServer.whereis(Dust.Connection) do
        nil -> %{status: :not_started, url: nil, device_id: nil, uptime_seconds: nil}
        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            Dust.Connection.info(pid)
          else
            %{status: :not_started, url: nil, device_id: nil, uptime_seconds: nil}
          end
      end
    end

    defp fetch_stores do
      case Process.whereis(Dust.SyncEngineRegistry) do
        nil ->
          []

        _pid ->
          Registry.select(Dust.SyncEngineRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
          |> Enum.flat_map(fn {_store, pid} ->
            if Process.alive?(pid) do
              case GenServer.call(pid, :status, 1000) do
                status when is_map(status) -> [status]
                _ -> []
              end
            else
              []
            end
          end)
          |> Enum.sort_by(& &1.store)
      end
    end

    defp browse_store(store, cursor, pattern) do
      case Process.whereis(Dust.SyncEngineRegistry) do
        nil ->
          {[], nil}

        _pid ->
          case Registry.lookup(Dust.SyncEngineRegistry, store) do
            [{pid, _}] when is_pid(pid) ->
              if Process.alive?(pid) do
                %{cache: cache_mod, cache_target: target} = :sys.get_state(pid)

                if function_exported?(cache_mod, :browse, 3) do
                  opts = [limit: 50, cursor: cursor]
                  opts = if pattern != "", do: Keyword.put(opts, :pattern, pattern), else: opts
                  cache_mod.browse(target, store, opts)
                else
                  {[], nil}
                end
              else
                {[], nil}
              end

            _ ->
              {[], nil}
          end
      end
    end

    defp fetch_activity(store) do
      case :ets.whereis(Dust.ActivityBuffer) do
        :undefined -> []
        _ref -> Dust.ActivityBuffer.recent(Dust.ActivityBuffer, store, 50)
      end
    end

    # Formatting helpers

    defp status_color(:connected), do: "#28a745"
    defp status_color(:disconnected), do: "#dc3545"
    defp status_color(:reconnecting), do: "#ffc107"
    defp status_color(:not_started), do: "#6c757d"
    defp status_color(_), do: "#6c757d"

    defp format_uptime(nil), do: "—"
    defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
    defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
    defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

    defp format_time(%DateTime{} = dt) do
      Calendar.strftime(dt, "%H:%M:%S")
    end

    defp format_time(_), do: "—"

    defp truncate_value(value) when is_binary(value) and byte_size(value) > 80 do
      String.slice(value, 0, 80) <> "..."
    end

    defp truncate_value(value) when is_map(value) or is_list(value) do
      inspected = inspect(value, limit: 5, printable_limit: 80)
      if String.length(inspected) > 80, do: String.slice(inspected, 0, 80) <> "...", else: inspected
    end

    defp truncate_value(value), do: inspect(value)
  end
end
