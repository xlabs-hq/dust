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

  describe "connected?/1" do
    test "returns false when no process exists by that name" do
      refute Dust.Connection.connected?(:no_such_dust_connection)
    end

    test "returns false during the initial :disconnected state" do
      name = :"conn_status_test_#{System.unique_integer()}"

      {:ok, _pid} =
        Dust.Connection.start_link(
          url: "ws://localhost:7755/ws/sync",
          token: "test_token",
          stores: ["test/store"],
          test_mode?: true,
          name: name
        )

      refute Dust.Connection.connected?(name)
    end
  end

  describe "telemetry [:dust, :connection, :state_change]" do
    test "fires on init with from=nil, to=:disconnected" do
      handler_id = "test-init-#{System.unique_integer()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:dust, :connection, :state_change],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:state_change, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _pid} =
        Dust.Connection.start_link(
          url: "ws://localhost:7755/ws/sync",
          token: "test_token",
          stores: ["test/store"],
          test_mode?: true,
          name: :"telem_test_#{System.unique_integer()}"
        )

      assert_receive {:state_change, %{system_time: _}, metadata}, 200
      assert metadata.from == nil
      assert metadata.to == :disconnected
      assert metadata.url == "ws://localhost:7755/ws/sync"
      assert metadata.stores == ["test/store"]
    end
  end
end
