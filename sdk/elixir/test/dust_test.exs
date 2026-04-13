defmodule DustTest do
  use ExUnit.Case

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} =
      Dust.SyncEngine.start_link(
        store: "test/store",
        cache: {Dust.Cache.Memory, []}
      )

    :ok
  end

  test "Dust.entry/2 delegates to SyncEngine" do
    :ok = Dust.SyncEngine.seed_entry("test/store", "a", 1, "integer")
    assert {:ok, %Dust.Entry{path: "a", value: 1, revision: _}} = Dust.entry("test/store", "a")
  end
end
