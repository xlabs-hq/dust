defmodule Dust.Sync.TypedValuesTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "typed@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Typed", slug: "typed"})
    {:ok, store} = Stores.create_store(org, %{name: "products"})
    %{store: store}
  end

  describe "Decimal values" do
    test "write and read back a Decimal", %{store: store} do
      price = Decimal.new("29.99")

      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "products.shoe.price",
          value: price,
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "products.shoe.price")
      assert %Decimal{} = entry.value
      assert Decimal.equal?(entry.value, Decimal.new("29.99"))
      assert entry.type == "decimal"
    end

    test "Decimal survives round-trip through jsonb", %{store: store} do
      original = Decimal.new("0.1")

      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "account.balance",
          value: original,
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "account.balance")
      assert Decimal.equal?(entry.value, original)
    end

    test "Decimal with high precision is preserved", %{store: store} do
      precise = Decimal.new("123456789.123456789")

      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "precise.value",
          value: precise,
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "precise.value")
      assert Decimal.equal?(entry.value, precise)
    end

    test "Decimal in merge operation", %{store: store} do
      {:ok, _} =
        Sync.write(store.id, %{
          op: :merge,
          path: "product",
          value: %{"price" => Decimal.new("9.99"), "name" => "Widget"},
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "product.price")
      assert %Decimal{} = entry.value
      assert Decimal.equal?(entry.value, Decimal.new("9.99"))

      name_entry = Sync.get_entry(store.id, "product.name")
      assert name_entry.value == "Widget"
    end
  end

  describe "DateTime values" do
    test "write and read back a DateTime", %{store: store} do
      dt = ~U[2026-03-31 12:00:00Z]

      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "events.launch.date",
          value: dt,
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "events.launch.date")
      assert %DateTime{} = entry.value
      assert DateTime.compare(entry.value, dt) == :eq
      assert entry.type == "datetime"
    end

    test "DateTime survives round-trip through jsonb", %{store: store} do
      original = ~U[2026-01-15 08:30:00Z]

      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "task.due_at",
          value: original,
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "task.due_at")
      assert DateTime.compare(entry.value, original) == :eq
    end

    test "DateTime with microsecond precision is preserved", %{store: store} do
      {:ok, precise, _} = DateTime.from_iso8601("2026-03-31T12:34:56.789012Z")

      {:ok, _} =
        Sync.write(store.id, %{
          op: :set,
          path: "event.precise_at",
          value: precise,
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "event.precise_at")
      assert DateTime.compare(entry.value, precise) == :eq
    end

    test "DateTime in merge operation", %{store: store} do
      dt = ~U[2026-06-15 09:00:00Z]

      {:ok, _} =
        Sync.write(store.id, %{
          op: :merge,
          path: "event",
          value: %{"starts_at" => dt, "title" => "Conference"},
          device_id: "d1",
          client_op_id: "o1"
        })

      entry = Sync.get_entry(store.id, "event.starts_at")
      assert %DateTime{} = entry.value
      assert DateTime.compare(entry.value, dt) == :eq

      title_entry = Sync.get_entry(store.id, "event.title")
      assert title_entry.value == "Conference"
    end
  end

  describe "get_all_entries with typed values" do
    test "returns Decimal and DateTime values correctly", %{store: store} do
      price = Decimal.new("49.99")
      dt = ~U[2026-03-31 00:00:00Z]

      Sync.write(store.id, %{
        op: :set,
        path: "item.price",
        value: price,
        device_id: "d1",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :set,
        path: "item.created_at",
        value: dt,
        device_id: "d1",
        client_op_id: "o2"
      })

      entries = Sync.get_all_entries(store.id)
      price_entry = Enum.find(entries, &(&1.path == "item.price"))
      dt_entry = Enum.find(entries, &(&1.path == "item.created_at"))

      assert %Decimal{} = price_entry.value
      assert Decimal.equal?(price_entry.value, price)
      assert %DateTime{} = dt_entry.value
      assert DateTime.compare(dt_entry.value, dt) == :eq
    end
  end
end
