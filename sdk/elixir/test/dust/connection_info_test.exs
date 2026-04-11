defmodule Dust.ConnectionInfoTest do
  use ExUnit.Case, async: true

  test "info/1 returns connection metadata" do
    opts = [
      url: "ws://localhost:7755/ws/sync",
      token: "test_token",
      device_id: "dev_test123",
      stores: ["test/store"],
      test_mode?: true,
      name: :"conn_info_test_#{System.unique_integer()}"
    ]

    {:ok, pid} = Dust.Connection.start_link(opts)

    info = Dust.Connection.info(pid)
    assert info.url == "ws://localhost:7755/ws/sync"
    assert info.device_id == "dev_test123"
    assert info.status == :disconnected
    assert info.connected_at == nil
  end
end
