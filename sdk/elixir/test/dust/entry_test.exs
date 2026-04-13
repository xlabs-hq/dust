defmodule Dust.EntryTest do
  use ExUnit.Case, async: true

  test "new/1 builds an entry with revision from seq" do
    entry = Dust.Entry.new(path: "a.b", value: 1, type: "integer", revision: 42)
    assert entry.path == "a.b"
    assert entry.value == 1
    assert entry.type == "integer"
    assert entry.revision == 42
  end
end
