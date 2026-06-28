defmodule AdminWeb.StoreDetailLiveTest do
  # async: false — Sync.write/2 persists ops to a per-store SQLite database
  # outside the Ecto sandbox transaction.
  use AdminWeb.ConnCase, async: false

  import Dust.AccountsFixtures

  alias Dust.Repo
  alias Dust.Stores
  alias Dust.Stores.Store
  alias Dust.Sync

  setup do
    org = organization_fixture(%{slug: "store-detail-org"})
    {:ok, store} = Stores.create_store(org, %{name: "detail-store"})

    {:ok, _op} =
      Sync.write(store.id, %{
        op: :set,
        path: "greeting",
        value: "hello",
        device_id: "test-device",
        client_op_id: "op-1"
      })

    %{store: store}
  end

  test "renders the ops table without crashing on string timestamps", %{conn: conn, store: store} do
    {:ok, _view, html} = live(conn, ~p"/stores/#{store.id}")

    assert html =~ "detail-store"
    assert html =~ "greeting"
    # The op timestamp is formatted as YYYY-MM-DD HH:MM:SS rather than raising
    # a FunctionClauseError in Calendar.strftime/3 (the original bug).
    assert html =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/
  end

  test "warns when recorded counts have no backing data on disk", %{conn: conn} do
    org = organization_fixture(%{slug: "ghost-data-org"})
    # A store row claiming ops/entries but with no per-store SQLite database.
    store =
      Repo.insert!(%Store{
        organization_id: org.id,
        name: "ghost-store",
        status: :active,
        entry_count: 7,
        op_count: 8
      })

    {:ok, view, _html} = live(conn, ~p"/stores/#{store.id}")

    assert has_element?(view, "#data-missing-warning")
  end
end
