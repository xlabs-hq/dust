defmodule DustWeb.StoreController do
  use DustWeb, :controller

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    stores = Dust.Stores.list_stores(scope.organization)

    conn
    |> assign(:page_title, "Stores")
    |> render_inertia("Stores/Index", %{
      stores: serialize_stores(stores, scope.organization)
    })
  end

  def show(conn, %{"name" => store_name}) do
    scope = conn.assigns.current_scope
    store = Dust.Stores.get_store_by_org_and_name!(scope.organization, store_name)
    entries = Dust.Sync.get_entries_page(store.id, limit: 100)
    ops = Dust.Sync.get_ops_page(store.id, limit: 50)
    current_seq = Dust.Sync.current_seq(store.id)

    conn
    |> assign(:page_title, store.name)
    |> render_inertia("Stores/Show", %{
      store: serialize_store(store, scope.organization),
      entries: serialize_entries(entries),
      ops: serialize_ops(ops),
      current_seq: current_seq
    })
  end

  def new(conn, _params) do
    conn
    |> assign(:page_title, "Create Store")
    |> render_inertia("Stores/Create", %{})
  end

  def create(conn, %{"name" => name}) do
    scope = conn.assigns.current_scope

    case Dust.Stores.create_store(scope.organization, %{name: name}) do
      {:ok, store} ->
        conn
        |> put_flash(:info, "Store created")
        |> redirect(to: ~p"/#{scope.organization.slug}/stores/#{store.name}")

      {:error, changeset} ->
        conn
        |> assign(:page_title, "Create Store")
        |> render_inertia("Stores/Create", %{errors: format_errors(changeset)})
    end
  end

  # Serialization

  defp serialize_stores(stores, organization) do
    Enum.map(stores, fn store -> serialize_store(store, organization) end)
  end

  defp serialize_store(store, organization) do
    %{
      id: store.id,
      name: store.name,
      full_name: "#{organization.slug}/#{store.name}",
      status: store.status,
      inserted_at: store.inserted_at,
      expires_at: store.expires_at,
      entry_count: Dust.Sync.entry_count(store.id)
    }
  end

  defp serialize_entries(entries) do
    Enum.map(entries, fn entry ->
      %{
        path: entry.path,
        value: entry.value,
        type: entry.type,
        seq: entry.seq
      }
    end)
  end

  defp serialize_ops(ops) do
    Enum.map(ops, fn op ->
      %{
        store_seq: op.store_seq,
        op: op.op,
        path: op.path,
        value: op.value,
        device_id: op.device_id,
        inserted_at: op.inserted_at
      }
    end)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
