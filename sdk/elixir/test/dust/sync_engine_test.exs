defmodule Dust.SyncEngineTest do
  use ExUnit.Case

  alias Dust.SyncEngine

  setup do
    start_supervised!({Registry, keys: :unique, name: Dust.SyncEngineRegistry})
    start_supervised!({Registry, keys: :unique, name: Dust.ConnectionRegistry})

    {:ok, _pid} = SyncEngine.start_link(
      store: "test/store",
      cache: {Dust.Cache.Memory, []}
    )

    :ok
  end

  test "put and get" do
    :ok = SyncEngine.put("test/store", "posts.hello", %{"title" => "Hello"})
    assert {:ok, %{"title" => "Hello"}} = SyncEngine.get("test/store", "posts.hello")
  end

  test "delete" do
    SyncEngine.put("test/store", "x", "value")
    SyncEngine.delete("test/store", "x")
    assert :miss = SyncEngine.get("test/store", "x")
  end

  test "merge updates children" do
    SyncEngine.put("test/store", "settings.theme", "light")
    SyncEngine.merge("test/store", "settings", %{"theme" => "dark", "locale" => "en"})
    assert {:ok, "dark"} = SyncEngine.get("test/store", "settings.theme")
    assert {:ok, "en"} = SyncEngine.get("test/store", "settings.locale")
  end

  test "entry/2 returns {:ok, %Dust.Entry{}} for present leaf" do
    :ok = SyncEngine.seed_entry("test/store", "a.b", "hello", "string")

    assert {:ok, %Dust.Entry{path: "a.b", value: "hello", type: "string", revision: rev}} =
             SyncEngine.entry("test/store", "a.b")

    assert is_integer(rev)
  end

  test "entry/2 returns {:error, :not_found} for missing path" do
    assert SyncEngine.entry("test/store", "nope") == {:error, :not_found}
  end

  test "enum returns matching entries" do
    SyncEngine.put("test/store", "posts.a", "1")
    SyncEngine.put("test/store", "posts.b", "2")
    SyncEngine.put("test/store", "config.x", "3")

    results = SyncEngine.enum("test/store", "posts.*")
    assert length(results) == 2
  end

  # enum/3 paged tests

  test "enum/3 returns %Dust.Page{} with %Dust.Entry{} items by default" do
    :ok = SyncEngine.put("test/store", "posts.a", "1")
    :ok = SyncEngine.put("test/store", "posts.b", "2")

    page = SyncEngine.enum("test/store", "posts.*", [])
    assert %Dust.Page{} = page
    assert length(page.items) == 2
    assert Enum.all?(page.items, &match?(%Dust.Entry{}, &1))
    paths = Enum.map(page.items, & &1.path) |> Enum.sort()
    assert paths == ["posts.a", "posts.b"]
  end

  test "enum/3 with select: :keys returns a Page of path strings" do
    :ok = SyncEngine.put("test/store", "posts.a", "1")
    :ok = SyncEngine.put("test/store", "posts.b", "2")

    page = SyncEngine.enum("test/store", "posts.*", select: :keys)
    assert %Dust.Page{} = page
    assert Enum.sort(page.items) == ["posts.a", "posts.b"]
  end

  test "enum/3 with select: :prefixes and valid pattern returns a Page of prefix strings" do
    :ok = SyncEngine.put("test/store", "posts.a.title", "hi")
    :ok = SyncEngine.put("test/store", "posts.b.title", "yo")

    page = SyncEngine.enum("test/store", "posts.**", select: :prefixes)
    assert %Dust.Page{} = page
    assert Enum.all?(page.items, &is_binary/1)
    assert "posts.a" in page.items
    assert "posts.b" in page.items
  end

  test "enum/3 with select: :prefixes and invalid pattern returns tagged error tuple" do
    :ok = SyncEngine.put("test/store", "a.x.b", "1")

    assert SyncEngine.enum("test/store", "a.*.b", select: :prefixes) ==
             {:error, :invalid_pattern_for_prefixes}
  end

  # range/4 tests

  test "range/4 returns a Page with entries in [from, to)" do
    for k <- ~w(a b c d e), do: SyncEngine.seed_entry("test/store", k, k, "string")

    assert %Dust.Page{items: items, next_cursor: nil} =
             SyncEngine.range("test/store", "a", "d", limit: 10)

    paths = Enum.map(items, & &1.path)
    assert paths == ~w(a b c)
  end

  test "range/4 with select: :keys returns path strings" do
    for k <- ~w(a b c), do: SyncEngine.seed_entry("test/store", k, k, "string")

    assert %Dust.Page{items: ~w(a b c)} =
             SyncEngine.range("test/store", "a", "z", select: :keys)
  end

  test "range/4 rejects select: :prefixes" do
    assert SyncEngine.range("test/store", "a", "z", select: :prefixes) ==
             {:error, :unsupported_select}
  end

  test "range/4 with from >= to returns an empty page" do
    :ok = SyncEngine.seed_entry("test/store", "x", "x", "string")

    assert %Dust.Page{items: [], next_cursor: nil} =
             SyncEngine.range("test/store", "z", "a")
  end

  test "enum/3 honors :limit option" do
    :ok = SyncEngine.put("test/store", "items.a", "1")
    :ok = SyncEngine.put("test/store", "items.b", "2")
    :ok = SyncEngine.put("test/store", "items.c", "3")

    page = SyncEngine.enum("test/store", "items.*", limit: 2)
    assert %Dust.Page{} = page
    assert length(page.items) == 2
    assert page.next_cursor != nil
  end

  test "on fires callback for matching writes" do
    test_pid = self()
    SyncEngine.on("test/store", "posts.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "posts.hello", "value")
    assert_receive {:event, %{path: "posts.hello", committed: false, source: :local}}, 500
  end

  test "on does not fire for non-matching writes" do
    test_pid = self()
    SyncEngine.on("test/store", "posts.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "config.x", "value")
    refute_receive {:event, _}
  end

  test "status reports state" do
    status = SyncEngine.status("test/store")
    assert status.connection == :disconnected
    assert status.last_store_seq == 0
    assert status.pending_ops >= 0
  end

  test "works with Ecto cache adapter (module target)" do
    {:ok, _pid} =
      SyncEngine.start_link(
        store: "ecto/store",
        cache: {Dust.Cache.Ecto, Dust.TestRepo}
      )

    :ok = SyncEngine.put("ecto/store", "key", "value")
    assert {:ok, "value"} = SyncEngine.get("ecto/store", "key")
  end

  # Counter tests

  test "increment creates counter from nothing" do
    :ok = SyncEngine.increment("test/store", "stats.views", 5)
    assert {:ok, 5} = SyncEngine.get("test/store", "stats.views")
  end

  test "increment accumulates" do
    :ok = SyncEngine.increment("test/store", "stats.views", 3)
    :ok = SyncEngine.increment("test/store", "stats.views", 7)
    assert {:ok, 10} = SyncEngine.get("test/store", "stats.views")
  end

  test "increment defaults to 1" do
    :ok = SyncEngine.increment("test/store", "counter.default")
    assert {:ok, 1} = SyncEngine.get("test/store", "counter.default")
  end

  test "increment by negative (decrement)" do
    :ok = SyncEngine.increment("test/store", "stats.views", 10)
    :ok = SyncEngine.increment("test/store", "stats.views", -3)
    assert {:ok, 7} = SyncEngine.get("test/store", "stats.views")
  end

  test "increment fires callback" do
    test_pid = self()
    SyncEngine.on("test/store", "stats.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.increment("test/store", "stats.views", 5)
    assert_receive {:event, %{path: "stats.views", op: :increment, value: 5, committed: false}}, 500
  end

  # Set tests

  test "add creates set from nothing" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    assert {:ok, ["elixir"]} = SyncEngine.get("test/store", "post.tags")
  end

  test "add is idempotent" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    assert {:ok, ["elixir"]} = SyncEngine.get("test/store", "post.tags")
  end

  test "add multiple members" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    :ok = SyncEngine.add("test/store", "post.tags", "rust")
    {:ok, tags} = SyncEngine.get("test/store", "post.tags")
    assert "elixir" in tags
    assert "rust" in tags
  end

  test "remove deletes member" do
    :ok = SyncEngine.add("test/store", "post.tags", "elixir")
    :ok = SyncEngine.add("test/store", "post.tags", "rust")
    :ok = SyncEngine.remove("test/store", "post.tags", "elixir")
    assert {:ok, ["rust"]} = SyncEngine.get("test/store", "post.tags")
  end

  test "remove from nonexistent set" do
    :ok = SyncEngine.remove("test/store", "post.tags", "elixir")
    assert {:ok, []} = SyncEngine.get("test/store", "post.tags")
  end

  test "add fires callback" do
    test_pid = self()
    SyncEngine.on("test/store", "post.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.add("test/store", "post.tags", "elixir")
    assert_receive {:event, %{path: "post.tags", op: :add, value: "elixir", committed: false}}, 500
  end

  test "remove fires callback" do
    test_pid = self()
    SyncEngine.add("test/store", "post.tags", "elixir")
    SyncEngine.on("test/store", "post.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.remove("test/store", "post.tags", "elixir")
    assert_receive {:event, %{path: "post.tags", op: :remove, value: "elixir", committed: false}}, 500
  end

  # Write rejection tests

  test "handle_write_rejected rolls back to previous value" do
    # Write a value and get its op_id so we can simulate acceptance
    :ok = SyncEngine.put("test/store", "key", "committed")

    state = :sys.get_state(SyncEngine.via("test/store") |> GenServer.whereis())
    [{first_op_id, _}] = Map.to_list(state.pending_ops)

    # Simulate server accepting the first write
    SyncEngine.handle_server_event("test/store", %{
      "op" => "set", "path" => "key", "value" => "committed",
      "store_seq" => 1, "device_id" => "d", "client_op_id" => first_op_id
    })

    # Now do an optimistic update
    :ok = SyncEngine.put("test/store", "key", "optimistic")
    assert {:ok, "optimistic"} = SyncEngine.get("test/store", "key")

    state = :sys.get_state(SyncEngine.via("test/store") |> GenServer.whereis())
    [{client_op_id, _op}] = Map.to_list(state.pending_ops)

    SyncEngine.handle_write_rejected("test/store", client_op_id, "limit_exceeded")

    # Should restore to "committed", not delete
    assert {:ok, "committed"} = SyncEngine.get("test/store", "key")
  end

  test "handle_write_rejected deletes if no previous value" do
    :ok = SyncEngine.put("test/store", "new_key", "optimistic")
    assert {:ok, "optimistic"} = SyncEngine.get("test/store", "new_key")

    state = :sys.get_state(SyncEngine.via("test/store") |> GenServer.whereis())
    [{client_op_id, _op}] = Map.to_list(state.pending_ops)

    SyncEngine.handle_write_rejected("test/store", client_op_id, "limit_exceeded")

    # No previous value, so it should be gone
    assert :miss = SyncEngine.get("test/store", "new_key")
  end

  test "handle_write_rejected fires rejection callback" do
    test_pid = self()
    SyncEngine.on("test/store", "key", fn event -> send(test_pid, {:event, event}) end)

    :ok = SyncEngine.put("test/store", "key", "optimistic")
    # Consume the optimistic callback
    assert_receive {:event, %{committed: false, source: :local}}, 500

    state = :sys.get_state(SyncEngine.via("test/store") |> GenServer.whereis())
    [{client_op_id, _op}] = Map.to_list(state.pending_ops)

    SyncEngine.handle_write_rejected("test/store", client_op_id, "rate_limited")

    # Should receive a rejection callback
    assert_receive {:event, %{error: %{code: :rejected, message: "rate_limited"}}}, 500
  end

  # Decimal tests

  test "put and get Decimal value" do
    price = Decimal.new("29.99")
    :ok = SyncEngine.put("test/store", "product.price", price)
    assert {:ok, ^price} = SyncEngine.get("test/store", "product.price")
  end

  test "Decimal detect_type returns decimal" do
    test_pid = self()
    SyncEngine.on("test/store", "item.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "item.price", Decimal.new("9.99"))
    assert_receive {:event, %{path: "item.price", op: :set, value: %Decimal{}, committed: false}}, 500
  end

  # DateTime tests

  test "put and get DateTime value" do
    dt = ~U[2026-03-31 12:00:00Z]
    :ok = SyncEngine.put("test/store", "event.starts_at", dt)
    assert {:ok, ^dt} = SyncEngine.get("test/store", "event.starts_at")
  end

  test "DateTime detect_type returns datetime" do
    test_pid = self()
    SyncEngine.on("test/store", "event.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put("test/store", "event.starts_at", ~U[2026-03-31 12:00:00Z])
    assert_receive {:event, %{path: "event.starts_at", op: :set, value: %DateTime{}, committed: false}}, 500
  end

  # File tests

  test "put_file stores reference in cache" do
    # Create a temp file
    tmp = Path.join(System.tmp_dir!(), "dust_test_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "hello world")

    :ok = SyncEngine.put_file("test/store", "docs.readme", tmp)

    {:ok, ref} = SyncEngine.get("test/store", "docs.readme")
    assert %Dust.FileRef{} = ref
    assert ref.hash == "sha256:" <> (:crypto.hash(:sha256, "hello world") |> Base.encode16(case: :lower))
    assert ref.size == 11
    assert ref.filename == Path.basename(tmp)
    assert ref.content_type == "application/octet-stream"
  after
    File.rm(Path.join(System.tmp_dir!(), "dust_test_*.txt"))
  end

  test "put_file accepts filename and content_type opts" do
    tmp = Path.join(System.tmp_dir!(), "dust_test_upload_#{System.unique_integer([:positive])}.bin")
    File.write!(tmp, <<0, 1, 2, 3>>)

    :ok = SyncEngine.put_file("test/store", "files.data", tmp,
      filename: "custom.dat",
      content_type: "application/octet-stream"
    )

    {:ok, ref} = SyncEngine.get("test/store", "files.data")
    assert ref.filename == "custom.dat"
    assert ref.content_type == "application/octet-stream"
  after
    File.rm(Path.join(System.tmp_dir!(), "dust_test_upload_*.bin"))
  end

  test "get returns FileRef for file entries" do
    file_map = %{
      "_type" => "file",
      "hash" => "sha256:abc123",
      "size" => 100,
      "content_type" => "text/plain",
      "filename" => "test.txt",
      "uploaded_at" => "2026-03-31T12:00:00Z"
    }

    # Write a file reference directly into cache
    SyncEngine.put("test/store", "files.doc", file_map)

    {:ok, ref} = SyncEngine.get("test/store", "files.doc")
    assert %Dust.FileRef{} = ref
    assert ref.hash == "sha256:abc123"
    assert ref.filename == "test.txt"
  end

  test "get returns plain value for non-file entries" do
    SyncEngine.put("test/store", "plain.key", "just a string")
    assert {:ok, "just a string"} = SyncEngine.get("test/store", "plain.key")

    SyncEngine.put("test/store", "plain.num", 42)
    assert {:ok, 42} = SyncEngine.get("test/store", "plain.num")

    SyncEngine.put("test/store", "plain.map", %{"foo" => "bar"})
    assert {:ok, %{"foo" => "bar"}} = SyncEngine.get("test/store", "plain.map")
  end

  test "put_file fires callback" do
    tmp = Path.join(System.tmp_dir!(), "dust_test_cb_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "callback test")

    test_pid = self()
    SyncEngine.on("test/store", "uploads.*", fn event -> send(test_pid, {:event, event}) end)
    SyncEngine.put_file("test/store", "uploads.file1", tmp)

    assert_receive {:event, %{path: "uploads.file1", op: :put_file, committed: false}}, 500
  after
    File.rm(Path.join(System.tmp_dir!(), "dust_test_cb_*.txt"))
  end
end
