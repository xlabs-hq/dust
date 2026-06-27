defmodule Dust.EntryTest do
  use ExUnit.Case, async: true

  test "new/1 builds an entry with revision from seq" do
    entry = Dust.Entry.new(path: "a/b", value: 1, type: "integer", revision: 42)
    assert entry.path == "a/b"
    assert entry.value == 1
    assert entry.type == "integer"
    assert entry.revision == 42
  end

  test "new/1 defaults synced_at to nil when not given" do
    entry = Dust.Entry.new(path: "a/b", value: 1, type: "integer", revision: 42)
    assert entry.synced_at == nil
  end

  test "new/1 carries synced_at when given" do
    entry =
      Dust.Entry.new(
        path: "a/b",
        value: 1,
        type: "integer",
        revision: 42,
        synced_at: 1_700_000_000
      )

    assert entry.synced_at == 1_700_000_000
  end
end
