defmodule DustEcto.RepoSubscribeTest do
  use ExUnit.Case, async: false

  alias DustEcto.Repo
  alias DustEcto.Test.Link

  @store "test/store"

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} =
      Dust.SyncEngine.start_link(store: @store, cache: {Dust.Cache.Memory, []})

    Application.put_env(:dust_ecto, :store, @store)
    Application.put_env(:dust_ecto, :dust_facade, Dust)

    on_exit(fn ->
      Application.delete_env(:dust_ecto, :store)
      Application.delete_env(:dust_ecto, :dust_facade)
    end)

    :ok
  end

  describe "subscribe/2" do
    test "delivers {:upserted, %Link{}} when an external write completes" do
      test_pid = self()
      assert {:ok, _ref} = Repo.subscribe(Link, fn evt -> send(test_pid, {:rec, evt}) end)

      # Seed a complete record's leaves into cache so the subscribe
      # wrapper can reassemble the struct on demand.
      :ok = Dust.SyncEngine.seed_entry(@store, "links/foo/title", "Foo", "string")
      :ok = Dust.SyncEngine.seed_entry(@store, "links/foo/url", "https://foo", "string")

      # Simulate an external server event that pulls the wrapper into
      # action.
      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 5,
        "op" => "set",
        "path" => "links/foo/title",
        "value" => "Foo",
        "device_id" => "other-dev",
        "client_op_id" => "external-1"
      })

      assert_receive {:rec, {:upserted, %Link{slug: "foo", title: "Foo"}}}, 500
    end

    test "delivers {:deleted, slug} on a delete event" do
      test_pid = self()
      assert {:ok, _ref} = Repo.subscribe(Link, fn evt -> send(test_pid, {:rec, evt}) end)

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 7,
        "op" => "delete",
        "path" => "links/foo",
        "value" => nil,
        "device_id" => "other-dev",
        "client_op_id" => "external-2"
      })

      assert_receive {:rec, {:deleted, "foo"}}, 500
    end

    test "drops events whose record fails the required-fields guard" do
      test_pid = self()
      {:ok, _ref} = Repo.subscribe(Link, fn evt -> send(test_pid, {:rec, evt}) end)

      # Seed only :title (missing required :url).
      :ok = Dust.SyncEngine.seed_entry(@store, "links/bar/title", "Bar", "string")

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 8,
        "op" => "set",
        "path" => "links/bar/title",
        "value" => "Bar",
        "device_id" => "other-dev",
        "client_op_id" => "external-3"
      })

      # No :upserted event because the record fails the guard.
      refute_receive {:rec, _}, 100
    end
  end

  describe "subscribe_raw/2" do
    test "delivers the raw event map without reassembly" do
      test_pid = self()
      assert {:ok, _ref} = Repo.subscribe_raw(Link, fn evt -> send(test_pid, {:raw, evt}) end)

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 9,
        "op" => "set",
        "path" => "links/foo/title",
        "value" => "Foo",
        "device_id" => "other-dev",
        "client_op_id" => "external-4"
      })

      assert_receive {:raw,
                      %{path: "links/foo/title", value: "Foo", store_seq: 9, committed: true}},
                     500
    end
  end

  describe "regression: dotted prefix subscriptions" do
    alias DustEcto.Test.DottedPrefixLink

    test "delivers {:upserted, struct} for events under a dotted prefix" do
      test_pid = self()

      {:ok, _ref} =
        Repo.subscribe(DottedPrefixLink, fn evt -> send(test_pid, {:rec, evt}) end)

      :ok = Dust.SyncEngine.seed_entry(@store, "reading/links/foo/title", "Foo", "string")

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 21,
        "op" => "set",
        "path" => "reading/links/foo/title",
        "value" => "Foo",
        "device_id" => "other",
        "client_op_id" => "dp-1"
      })

      assert_receive {:rec, {:upserted, %DottedPrefixLink{slug: "foo", title: "Foo"}}}, 500
    end
  end

  describe "regression: field-level delete vs whole-record delete" do
    test "delete on a field path emits :upserted when record still loads" do
      test_pid = self()
      {:ok, _ref} = Repo.subscribe(Link, fn evt -> send(test_pid, {:rec, evt}) end)

      # Record has all required fields seeded.
      :ok = Dust.SyncEngine.seed_entry(@store, "links/foo/title", "Foo", "string")
      :ok = Dust.SyncEngine.seed_entry(@store, "links/foo/url", "https://foo", "string")
      :ok = Dust.SyncEngine.seed_entry(@store, "links/foo/note", "n", "string")

      # Server emits a :delete event for a non-required field path.
      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 30,
        "op" => "delete",
        "path" => "links/foo/note",
        "value" => nil,
        "device_id" => "other",
        "client_op_id" => "fd-1"
      })

      assert_receive {:rec, {:upserted, %Link{slug: "foo"}}}, 500
      refute_received {:rec, {:deleted, "foo"}}
    end

    test "delete on the slug root path emits :deleted" do
      test_pid = self()
      {:ok, _ref} = Repo.subscribe(Link, fn evt -> send(test_pid, {:rec, evt}) end)

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 31,
        "op" => "delete",
        "path" => "links/foo",
        "value" => nil,
        "device_id" => "other",
        "client_op_id" => "rd-1"
      })

      assert_receive {:rec, {:deleted, "foo"}}, 500
    end
  end

  describe "unsubscribe/1" do
    test "stops further deliveries" do
      test_pid = self()
      {:ok, ref} = Repo.subscribe(Link, fn evt -> send(test_pid, {:rec, evt}) end)

      :ok = Repo.unsubscribe(ref)

      Dust.SyncEngine.handle_server_event(@store, %{
        "store_seq" => 10,
        "op" => "set",
        "path" => "links/foo/title",
        "value" => "Foo",
        "device_id" => "other-dev",
        "client_op_id" => "external-5"
      })

      refute_receive {:rec, _}, 100
    end
  end
end
