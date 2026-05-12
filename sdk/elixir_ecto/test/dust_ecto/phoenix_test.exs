defmodule DustEcto.PhoenixTest do
  use ExUnit.Case, async: false

  alias DustEcto.Error
  alias DustEcto.Test.Link

  @store "test/phoenix-store"

  setup do
    # SDK transport requires these two registries and a running engine.
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} =
      Dust.SyncEngine.start_link(store: @store, cache: {Dust.Cache.Memory, []})

    # Phoenix.PubSub for this test only — a unique name per test so the
    # global DustEcto.Phoenix.Registry can hold many broadcasters across
    # the suite without collisions.
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    Application.put_env(:dust_ecto, :store, @store)
    Application.put_env(:dust_ecto, :dust_facade, Dust)

    on_exit(fn ->
      Application.delete_env(:dust_ecto, :store)
      Application.delete_env(:dust_ecto, :dust_facade)
    end)

    %{pubsub: pubsub, topic: "links-#{System.unique_integer([:positive])}"}
  end

  describe "subscribe_to_pubsub/3" do
    test "delivers {:dust_event, {:upserted, struct}} for an external write", %{
      pubsub: pubsub,
      topic: topic
    } do
      :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, pubsub, topic)

      :ok = Dust.SyncEngine.seed_entry(@store, "links.foo.title", "Foo", "string")
      :ok = Dust.SyncEngine.seed_entry(@store, "links.foo.url", "https://foo", "string")

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 5,
        "op" => "set",
        "path" => "links.foo.title",
        "value" => "Foo",
        "device_id" => "ext",
        "client_op_id" => "p-1"
      })

      assert_receive {:dust_event, {:upserted, %Link{slug: "foo", title: "Foo"}}}, 500
    end

    test "delivers {:dust_event, {:deleted, slug}} on a delete event", %{
      pubsub: pubsub,
      topic: topic
    } do
      :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, pubsub, topic)

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 6,
        "op" => "delete",
        "path" => "links.foo",
        "value" => nil,
        "device_id" => "ext",
        "client_op_id" => "p-2"
      })

      assert_receive {:dust_event, {:deleted, "foo"}}, 500
    end

    test "is idempotent — two callers share one broadcaster", %{
      pubsub: pubsub,
      topic: topic
    } do
      :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, pubsub, topic)
      :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, pubsub, topic)

      assert [{_pid, _}] =
               Registry.lookup(DustEcto.Phoenix.Registry, {Link, pubsub, topic})
    end

    test "two LiveView-shaped processes both receive the same broadcast", %{
      pubsub: pubsub,
      topic: topic
    } do
      test_pid = self()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, pubsub, topic)
            send(test_pid, {:ready, i})

            receive do
              {:dust_event, _} = msg -> msg
            after
              500 -> :timeout
            end
          end)
        end

      assert_receive {:ready, 1}, 200
      assert_receive {:ready, 2}, 200

      :ok = Dust.SyncEngine.seed_entry(@store, "links.fan.title", "Fan", "string")
      :ok = Dust.SyncEngine.seed_entry(@store, "links.fan.url", "https://fan", "string")

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 10,
        "op" => "set",
        "path" => "links.fan.title",
        "value" => "Fan",
        "device_id" => "ext",
        "client_op_id" => "fan-1"
      })

      results = Task.await_many(tasks, 1_000)
      assert Enum.all?(results, &match?({:dust_event, {:upserted, %Link{slug: "fan"}}}, &1))
    end
  end

  describe "subscribe_to_pubsub/3 — error paths" do
    test "returns :not_supported when SDK transport isn't available", %{pubsub: pubsub} do
      # Point at a store that no SyncEngine is registered for AND drop
      # the facade. Both signals Transport.pick/0 uses to choose SDK
      # mode are now off — it'll fall through to HTTP, whose subscribe
      # returns :not_supported.
      Application.delete_env(:dust_ecto, :dust_facade)
      Application.put_env(:dust_ecto, :store, "no-such/store")
      Application.put_env(:dust_ecto, :base_url, "http://stub")
      Application.put_env(:dust_ecto, :token, "tok")

      fresh_topic = "no-sdk-#{System.unique_integer([:positive])}"

      assert {:error, %Error{kind: :not_supported}} =
               DustEcto.Phoenix.subscribe_to_pubsub(Link, pubsub, fresh_topic)
    after
      Application.delete_env(:dust_ecto, :base_url)
      Application.delete_env(:dust_ecto, :token)
    end
  end

  describe "stop_broadcaster/3" do
    test "stops the broadcaster; further subscribers see no events", %{
      pubsub: pubsub,
      topic: topic
    } do
      :ok = DustEcto.Phoenix.subscribe_to_pubsub(Link, pubsub, topic)
      assert [{pid, _}] = Registry.lookup(DustEcto.Phoenix.Registry, {Link, pubsub, topic})
      ref = Process.monitor(pid)

      :ok = DustEcto.Phoenix.stop_broadcaster(Link, pubsub, topic)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      # Registry cleans up entries asynchronously after the monitored
      # process dies — sync against it before re-checking the lookup.
      _ = :sys.get_state(DustEcto.Phoenix.Registry)
      assert Registry.lookup(DustEcto.Phoenix.Registry, {Link, pubsub, topic}) == []
    end

    test "is a no-op when no broadcaster is running", %{pubsub: pubsub} do
      assert :ok = DustEcto.Phoenix.stop_broadcaster(Link, pubsub, "never-started")
    end
  end
end
