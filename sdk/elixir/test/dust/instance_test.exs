defmodule Dust.InstanceTest do
  use ExUnit.Case

  defmodule TestDust do
    use Dust, otp_app: :dust_test
  end

  setup do
    Application.put_env(:dust_test, TestDust,
      stores: ["test/instance"],
      cache: {Dust.Cache.Memory, []},
      testing: :manual
    )

    start_supervised!(TestDust)
    :ok
  end

  test "facade module delegates put and get to SyncEngine" do
    :ok = TestDust.put("test/instance", "key", "value")
    assert {:ok, "value"} = TestDust.get("test/instance", "key")
  end

  test "facade module delegates delete" do
    :ok = TestDust.put("test/instance", "x", "val")
    :ok = TestDust.delete("test/instance", "x")
    assert :miss = TestDust.get("test/instance", "x")
  end

  test "facade module delegates merge" do
    :ok = TestDust.merge("test/instance", "settings", %{"theme" => "dark", "locale" => "en"})
    assert {:ok, "dark"} = TestDust.get("test/instance", "settings.theme")
    assert {:ok, "en"} = TestDust.get("test/instance", "settings.locale")
  end

  test "facade module delegates increment" do
    :ok = TestDust.increment("test/instance", "counter", 5)
    assert {:ok, 5} = TestDust.get("test/instance", "counter")
    :ok = TestDust.increment("test/instance", "counter")
    assert {:ok, 6} = TestDust.get("test/instance", "counter")
  end

  test "facade module delegates add and remove" do
    :ok = TestDust.add("test/instance", "tags", "elixir")
    :ok = TestDust.add("test/instance", "tags", "rust")
    {:ok, tags} = TestDust.get("test/instance", "tags")
    assert "elixir" in tags
    assert "rust" in tags

    :ok = TestDust.remove("test/instance", "tags", "elixir")
    assert {:ok, ["rust"]} = TestDust.get("test/instance", "tags")
  end

  test "facade module delegates enum" do
    :ok = TestDust.put("test/instance", "posts.a", "1")
    :ok = TestDust.put("test/instance", "posts.b", "2")
    :ok = TestDust.put("test/instance", "config.x", "3")

    results = TestDust.enum("test/instance", "posts.*")
    assert length(results) == 2
  end

  test "facade module delegates on (callbacks)" do
    test_pid = self()
    TestDust.on("test/instance", "events.*", fn event -> send(test_pid, {:event, event}) end)
    TestDust.put("test/instance", "events.click", "data")
    assert_receive {:event, %{path: "events.click", committed: false, source: :local}}, 500
  end

  test "facade module exposes status" do
    status = TestDust.status("test/instance")
    assert status.connection == :disconnected
    assert status.last_store_seq == 0
    assert status.pending_ops >= 0
  end

  test "child_spec reads from app config" do
    spec = TestDust.child_spec([])
    assert spec.id == TestDust
    assert spec.type == :supervisor
  end

  test "testing: :manual skips connection process" do
    # The supervisor should be running but no Connection process
    assert GenServer.whereis(Dust.Connection) == nil
  end

  test "testing: :manual defaults cache to Memory when not specified" do
    # Start a second supervisor with no :cache key — should default to Memory
    {:ok, sup} =
      Dust.Supervisor.start_link(
        stores: ["test/memdefault"],
        testing: :manual,
        name: :mem_test_sup
      )

    # The SyncEngine should be alive and working with Memory cache
    status = Dust.SyncEngine.status("test/memdefault")
    assert status.connection == :disconnected

    # Verify it actually works (put/get)
    :ok = Dust.SyncEngine.put("test/memdefault", "key", "val")
    assert {:ok, "val"} = Dust.SyncEngine.get("test/memdefault", "key")

    Supervisor.stop(sup)
  end
end
