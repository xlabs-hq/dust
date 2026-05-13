defmodule Dust.Sync.WriterTest do
  use Dust.DataCase, async: false

  alias Dust.{Accounts, Stores, Sync}

  setup do
    {:ok, user} = Accounts.create_user(%{email: "writer@example.com"})
    {:ok, org} = Accounts.create_organization_with_owner(user, %{name: "Test", slug: "test"})
    {:ok, store} = Stores.create_store(org, %{name: "blog"})
    %{store: store}
  end

  describe "write/1" do
    test "set assigns store_seq and persists", %{store: store} do
      {:ok, event} =
        Sync.write(store.id, %{
          op: :set,
          path: "posts/hello",
          value: %{"title" => "Hello"},
          device_id: "dev_1",
          client_op_id: "op_1"
        })

      assert event.store_seq == 1
      assert event.op == :set
      # The writer now stores canonical slash-rendered paths.
      assert event.path == "posts/hello"

      # Verify materialized entry
      entry = Sync.get_entry(store.id, "posts/hello")
      assert entry.value == %{"title" => "Hello"}
      assert entry.seq == 1
    end

    test "sequential writes increment store_seq", %{store: store} do
      {:ok, e1} =
        Sync.write(store.id, %{
          op: :set,
          path: "a",
          value: "1",
          device_id: "d",
          client_op_id: "o1"
        })

      {:ok, e2} =
        Sync.write(store.id, %{
          op: :set,
          path: "b",
          value: "2",
          device_id: "d",
          client_op_id: "o2"
        })

      assert e1.store_seq == 1
      assert e2.store_seq == 2
    end

    test "delete removes entry", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "x", value: "v", device_id: "d", client_op_id: "o1"})

      {:ok, _} =
        Sync.write(store.id, %{
          op: :delete,
          path: "x",
          value: nil,
          device_id: "d",
          client_op_id: "o2"
        })

      assert Sync.get_entry(store.id, "x") == nil
    end

    test "subtree delete treats `%` and `_` in segments as literals", %{store: store} do
      # Without LIKE-escaping the descendant prefix, `a%b/...` would
      # act as the SQL wildcard `a` + any-chars + `b/...` and
      # incidentally match (and delete) `axb/...`.
      for {path, suffix} <- [
            {"a%b/child", "pct"},
            {"axb/child", "x"},
            {"foo_bar/child", "us"},
            {"fooxbar/child", "xb"}
          ] do
        Sync.write(store.id, %{
          op: :set,
          path: path,
          value: suffix,
          device_id: "d",
          client_op_id: "seed:#{path}"
        })
      end

      {:ok, _} =
        Sync.write(store.id, %{
          op: :delete,
          path: "a%b",
          value: nil,
          device_id: "d",
          client_op_id: "del:pct"
        })

      assert Sync.get_entry(store.id, "a%b/child") == nil
      assert %{value: "x"} = Sync.get_entry(store.id, "axb/child")

      {:ok, _} =
        Sync.write(store.id, %{
          op: :delete,
          path: "foo_bar",
          value: nil,
          device_id: "d",
          client_op_id: "del:us"
        })

      assert Sync.get_entry(store.id, "foo_bar/child") == nil
      assert %{value: "xb"} = Sync.get_entry(store.id, "fooxbar/child")
    end

    test "subtree read treats `%` and `_` in segments as literals", %{store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "a%b/child",
        value: "pct",
        device_id: "d",
        client_op_id: "seed:pct"
      })

      Sync.write(store.id, %{
        op: :set,
        path: "axb/child",
        value: "x",
        device_id: "d",
        client_op_id: "seed:x"
      })

      # get_entry on a subtree path assembles only matching descendants.
      assert %{value: %{"child" => "pct"}, type: "map"} = Sync.get_entry(store.id, "a%b")
      assert %{value: %{"child" => "x"}, type: "map"} = Sync.get_entry(store.id, "axb")
    end

    test "merge updates named children only", %{store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "settings/theme",
        value: "light",
        device_id: "d",
        client_op_id: "o1"
      })

      Sync.write(store.id, %{
        op: :set,
        path: "settings/locale",
        value: "en",
        device_id: "d",
        client_op_id: "o2"
      })

      Sync.write(store.id, %{
        op: :merge,
        path: "settings",
        value: %{"theme" => "dark"},
        device_id: "d",
        client_op_id: "o3"
      })

      assert Sync.get_entry(store.id, "settings/theme").value == "dark"
      assert Sync.get_entry(store.id, "settings/locale").value == "en"
    end
  end

  describe "map expansion" do
    test "set with map value expands into leaf entries", %{store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "post",
        value: %{"title" => "Hello", "meta" => %{"author" => "james", "draft" => true}},
        device_id: "d",
        client_op_id: "o1"
      })

      # Leaf entries should exist
      assert Sync.get_entry(store.id, "post/title").value == "Hello"
      assert Sync.get_entry(store.id, "post/meta/author").value == "james"
      assert Sync.get_entry(store.id, "post/meta/draft").value == true

      # Parent path should reassemble the map
      entry = Sync.get_entry(store.id, "post")

      assert entry.value == %{
               "title" => "Hello",
               "meta" => %{"author" => "james", "draft" => true}
             }
    end

    test "merge with nested map expands into leaf entries", %{store: store} do
      # set("post", %{meta: %{author: "james", draft: true}})
      Sync.write(store.id, %{
        op: :set,
        path: "post",
        value: %{"meta" => %{"author" => "james", "draft" => true}},
        device_id: "d",
        client_op_id: "o1"
      })

      # merge("post", %{meta: %{draft: false}}) should expand and replace leaves
      Sync.write(store.id, %{
        op: :merge,
        path: "post",
        value: %{"meta" => %{"draft" => false}},
        device_id: "d",
        client_op_id: "o2"
      })

      # post.meta.draft should be false (updated)
      assert Sync.get_entry(store.id, "post/meta/draft").value == false
      # post.meta.author should be gone (merge replaced the meta subtree)
      assert Sync.get_entry(store.id, "post/meta/author") == nil

      # get("post") should show the correct assembled state
      entry = Sync.get_entry(store.id, "post")
      assert entry.value == %{"meta" => %{"draft" => false}}
    end

    test "set with scalar value stores as single entry", %{store: store} do
      Sync.write(store.id, %{
        op: :set,
        path: "key",
        value: "simple",
        device_id: "d",
        client_op_id: "o1"
      })

      assert Sync.get_entry(store.id, "key").value == "simple"
    end

    test "set with map value clears existing flat-leaf descendants", %{store: store} do
      # Seed the record's leaves the way a :flat-mode dust_ecto writer
      # would — three separate PUTs.
      for {field, value} <- [{"title", "Old"}, {"url", "https://old"}, {"note", "n"}] do
        Sync.write(store.id, %{
          op: :set,
          path: "links/foo/#{field}",
          value: value,
          device_id: "d",
          client_op_id: "seed-#{field}"
        })
      end

      # Now a :map-mode writer (or any client) PUTs the whole slug with
      # a *partial* map — title + url only, no note.
      Sync.write(store.id, %{
        op: :set,
        path: "links/foo",
        value: %{"title" => "New", "url" => "https://new"},
        device_id: "d",
        client_op_id: "replace"
      })

      # The pre-existing :note leaf must be gone — subtree replace, not
      # field-wise merge. Confirms the contract relied on by dust_ecto's
      # :flat ↔ :map crossover.
      assert Sync.get_entry(store.id, "links/foo/note") == nil
      assert Sync.get_entry(store.id, "links/foo/title").value == "New"
      assert Sync.get_entry(store.id, "links/foo/url").value == "https://new"

      # Re-assembled view returns only what was written.
      entry = Sync.get_entry(store.id, "links/foo")
      assert entry.value == %{"title" => "New", "url" => "https://new"}
    end

    test "set with scalar value clears existing flat-leaf descendants", %{store: store} do
      # Seed two descendants of the path.
      Sync.write(store.id, %{
        op: :set,
        path: "counters/foo/hits",
        value: 3,
        device_id: "d",
        client_op_id: "seed-1"
      })

      Sync.write(store.id, %{
        op: :set,
        path: "counters/foo/misses",
        value: 1,
        device_id: "d",
        client_op_id: "seed-2"
      })

      # Now overwrite the parent path with a scalar — descendants must
      # all clear, parent becomes the new scalar leaf.
      Sync.write(store.id, %{
        op: :set,
        path: "counters/foo",
        value: 0,
        device_id: "d",
        client_op_id: "replace"
      })

      assert Sync.get_entry(store.id, "counters/foo").value == 0
      assert Sync.get_entry(store.id, "counters/foo/hits") == nil
      assert Sync.get_entry(store.id, "counters/foo/misses") == nil
    end
  end

  describe "get_ops_since/2" do
    test "returns ops after given seq", %{store: store} do
      Sync.write(store.id, %{op: :set, path: "a", value: "1", device_id: "d", client_op_id: "o1"})
      Sync.write(store.id, %{op: :set, path: "b", value: "2", device_id: "d", client_op_id: "o2"})
      Sync.write(store.id, %{op: :set, path: "c", value: "3", device_id: "d", client_op_id: "o3"})

      ops = Sync.get_ops_since(store.id, 1)
      assert length(ops) == 2
      assert Enum.map(ops, & &1.store_seq) == [2, 3]
    end
  end
end
