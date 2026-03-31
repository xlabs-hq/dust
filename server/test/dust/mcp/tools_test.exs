defmodule Dust.MCP.ToolsTest do
  use Dust.DataCase

  alias Dust.IntegrationHelpers
  alias GenMCP.MCP
  alias GenMCP.Mux.Channel

  setup do
    %{org: org, store: store, token: token} = IntegrationHelpers.create_test_store("acme", "blog")

    # Re-authenticate to get preloaded store + organization
    {:ok, authed_token} = Dust.Stores.authenticate_token(token.raw_token)

    channel = %Channel{
      client: self(),
      progress_token: nil,
      status: :request,
      assigns: %{store_token: authed_token},
      log_level: :notice
    }

    store_full_name = "#{org.slug}/#{store.name}"

    %{
      org: org,
      store: store,
      token: authed_token,
      channel: channel,
      store_full_name: store_full_name
    }
  end

  defp make_req(arguments) do
    %MCP.CallToolRequest{
      params: %MCP.CallToolRequestParams{
        name: "test",
        arguments: arguments
      }
    }
  end

  describe "dust_get" do
    test "returns null for nonexistent path", ctx do
      req = make_req(%{"store" => ctx.store_full_name, "path" => "nonexistent"})
      {:result, result, _channel} = Dust.MCP.Tools.DustGet.call(req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert Jason.decode!(text) == nil
    end

    test "returns value for existing entry", ctx do
      Dust.Sync.write(ctx.store.id, %{
        op: :set,
        path: "greeting",
        value: "hello",
        device_id: "test",
        client_op_id: Ecto.UUID.generate()
      })

      req = make_req(%{"store" => ctx.store_full_name, "path" => "greeting"})
      {:result, result, _channel} = Dust.MCP.Tools.DustGet.call(req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert Jason.decode!(text) == "hello"
    end

    test "returns error for wrong store", ctx do
      req = make_req(%{"store" => "other/store", "path" => "foo"})
      {:error, reason, _channel} = Dust.MCP.Tools.DustGet.call(req, ctx.channel, [])
      assert reason =~ "not found"
    end
  end

  describe "dust_put" do
    test "writes a value and reads it back", ctx do
      put_req = make_req(%{"store" => ctx.store_full_name, "path" => "name", "value" => "Alice"})
      {:result, put_result, _channel} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = put_result
      assert text =~ "Wrote to name"

      # Read it back
      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "name"})
      {:result, get_result, _channel} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == "Alice"
    end

    test "writes a map value", ctx do
      put_req =
        make_req(%{
          "store" => ctx.store_full_name,
          "path" => "config",
          "value" => %{"theme" => "dark", "lang" => "en"}
        })

      {:result, _result, _channel} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "config"})
      {:result, get_result, _channel} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == %{"theme" => "dark", "lang" => "en"}
    end
  end

  describe "dust_delete" do
    test "removes an entry", ctx do
      # Write first
      put_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "to_delete", "value" => "bye"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      # Verify it exists
      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "to_delete"})
      {:result, result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert Jason.decode!(text) == "bye"

      # Delete
      del_req = make_req(%{"store" => ctx.store_full_name, "path" => "to_delete"})
      {:result, del_result, _} = Dust.MCP.Tools.DustDelete.call(del_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = del_result
      assert text =~ "Deleted to_delete"

      # Verify it's gone
      {:result, result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert Jason.decode!(text) == nil
    end
  end

  describe "dust_enum" do
    test "returns matching entries", ctx do
      # Write some entries
      for name <- ["alice", "bob", "carol"] do
        req =
          make_req(%{
            "store" => ctx.store_full_name,
            "path" => "users.#{name}",
            "value" => name
          })

        {:result, _, _} = Dust.MCP.Tools.DustPut.call(req, ctx.channel, [])
      end

      # Write an unrelated entry
      req =
        make_req(%{"store" => ctx.store_full_name, "path" => "settings.theme", "value" => "dark"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(req, ctx.channel, [])

      # Enum users.*
      enum_req = make_req(%{"store" => ctx.store_full_name, "pattern" => "users.*"})
      {:result, result, _} = Dust.MCP.Tools.DustEnum.call(enum_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      entries = Jason.decode!(text)
      assert length(entries) == 3
      paths = Enum.map(entries, & &1["path"])
      assert "users.alice" in paths
      assert "users.bob" in paths
      assert "users.carol" in paths
    end

    test "** matches everything", ctx do
      req =
        make_req(%{"store" => ctx.store_full_name, "path" => "foo", "value" => "bar"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(req, ctx.channel, [])

      enum_req = make_req(%{"store" => ctx.store_full_name, "pattern" => "**"})
      {:result, result, _} = Dust.MCP.Tools.DustEnum.call(enum_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      entries = Jason.decode!(text)
      assert length(entries) >= 1
    end
  end

  describe "dust_stores" do
    test "lists stores for the token", ctx do
      req = make_req(%{})
      {:result, result, _} = Dust.MCP.Tools.DustStores.call(req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      stores = Jason.decode!(text)
      assert length(stores) == 1
      assert hd(stores)["name"] == ctx.store_full_name
    end
  end

  describe "dust_status" do
    test "returns sync status", ctx do
      # Write an entry so seq > 0
      req =
        make_req(%{"store" => ctx.store_full_name, "path" => "key", "value" => "val"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(req, ctx.channel, [])

      status_req = make_req(%{"store" => ctx.store_full_name})
      {:result, result, _} = Dust.MCP.Tools.DustStatus.call(status_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      status = Jason.decode!(text)
      assert status["store"] == ctx.store_full_name
      assert status["current_seq"] >= 1
      assert status["entry_count"] >= 1
    end
  end

  describe "dust_merge" do
    test "merges keys into a path", ctx do
      # First set a base value
      put_req =
        make_req(%{
          "store" => ctx.store_full_name,
          "path" => "profile",
          "value" => %{"name" => "Alice"}
        })

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      # Merge additional keys
      merge_req =
        make_req(%{
          "store" => ctx.store_full_name,
          "path" => "profile",
          "value" => %{"age" => 30, "city" => "NYC"}
        })

      {:result, result, _} = Dust.MCP.Tools.DustMerge.call(merge_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert text =~ "Merged into profile"

      # Read back individual merge results
      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "profile.age"})
      {:result, result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert Jason.decode!(text) == 30
    end
  end

  describe "dust_log" do
    test "returns ops for a store", ctx do
      # Write some data first
      for i <- 1..3 do
        req =
          make_req(%{
            "store" => ctx.store_full_name,
            "path" => "key#{i}",
            "value" => "val#{i}"
          })

        {:result, _, _} = Dust.MCP.Tools.DustPut.call(req, ctx.channel, [])
      end

      log_req = make_req(%{"store" => ctx.store_full_name})
      {:result, result, _} = Dust.MCP.Tools.DustLog.call(log_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      ops = Jason.decode!(text)
      assert length(ops) == 3
      # Descending seq order
      seqs = Enum.map(ops, & &1["seq"])
      assert seqs == Enum.sort(seqs, :desc)
    end

    test "filters by path", ctx do
      for path <- ["a.x", "a.y", "b.z"] do
        req =
          make_req(%{
            "store" => ctx.store_full_name,
            "path" => path,
            "value" => "v"
          })

        {:result, _, _} = Dust.MCP.Tools.DustPut.call(req, ctx.channel, [])
      end

      log_req = make_req(%{"store" => ctx.store_full_name, "path" => "a.x"})
      {:result, result, _} = Dust.MCP.Tools.DustLog.call(log_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      ops = Jason.decode!(text)
      assert length(ops) == 1
      assert hd(ops)["path"] == "a.x"
    end

    test "filters by op type", ctx do
      put_req =
        make_req(%{
          "store" => ctx.store_full_name,
          "path" => "to_del",
          "value" => "v"
        })

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      del_req = make_req(%{"store" => ctx.store_full_name, "path" => "to_del"})
      {:result, _, _} = Dust.MCP.Tools.DustDelete.call(del_req, ctx.channel, [])

      log_req = make_req(%{"store" => ctx.store_full_name, "op" => "delete"})
      {:result, result, _} = Dust.MCP.Tools.DustLog.call(log_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      ops = Jason.decode!(text)
      assert length(ops) == 1
      assert hd(ops)["op"] == "delete"
    end

    test "respects limit", ctx do
      for i <- 1..5 do
        req =
          make_req(%{
            "store" => ctx.store_full_name,
            "path" => "item#{i}",
            "value" => "v"
          })

        {:result, _, _} = Dust.MCP.Tools.DustPut.call(req, ctx.channel, [])
      end

      log_req = make_req(%{"store" => ctx.store_full_name, "limit" => 2})
      {:result, result, _} = Dust.MCP.Tools.DustLog.call(log_req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      ops = Jason.decode!(text)
      assert length(ops) == 2
    end

    test "returns error for wrong store", ctx do
      req = make_req(%{"store" => "other/store"})
      {:error, reason, _} = Dust.MCP.Tools.DustLog.call(req, ctx.channel, [])
      assert reason =~ "not found"
    end
  end

  describe "dust_increment" do
    test "increments a counter from nothing", ctx do
      req = make_req(%{"store" => ctx.store_full_name, "path" => "stats.views", "delta" => 3})
      {:result, result, _} = Dust.MCP.Tools.DustIncrement.call(req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert text =~ "Incremented stats.views by 3"

      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "stats.views"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == 3
    end

    test "defaults delta to 1", ctx do
      req = make_req(%{"store" => ctx.store_full_name, "path" => "stats.hits"})
      {:result, result, _} = Dust.MCP.Tools.DustIncrement.call(req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert text =~ "by 1"

      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "stats.hits"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == 1
    end

    test "accumulates increments", ctx do
      req1 = make_req(%{"store" => ctx.store_full_name, "path" => "stats.views", "delta" => 3})
      {:result, _, _} = Dust.MCP.Tools.DustIncrement.call(req1, ctx.channel, [])

      req2 = make_req(%{"store" => ctx.store_full_name, "path" => "stats.views", "delta" => 5})
      {:result, _, _} = Dust.MCP.Tools.DustIncrement.call(req2, ctx.channel, [])

      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "stats.views"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == 8
    end
  end

  describe "dust_add" do
    test "adds a member to a set", ctx do
      req = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags", "member" => "elixir"})
      {:result, result, _} = Dust.MCP.Tools.DustAdd.call(req, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert text =~ "Added"

      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == ["elixir"]
    end

    test "adding multiple members", ctx do
      req1 = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags", "member" => "elixir"})
      {:result, _, _} = Dust.MCP.Tools.DustAdd.call(req1, ctx.channel, [])

      req2 = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags", "member" => "rust"})
      {:result, _, _} = Dust.MCP.Tools.DustAdd.call(req2, ctx.channel, [])

      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      members = Jason.decode!(text)
      assert "elixir" in members
      assert "rust" in members
    end
  end

  describe "dust_remove" do
    test "removes a member from a set", ctx do
      # Add first
      req1 = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags", "member" => "elixir"})
      {:result, _, _} = Dust.MCP.Tools.DustAdd.call(req1, ctx.channel, [])

      req2 = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags", "member" => "rust"})
      {:result, _, _} = Dust.MCP.Tools.DustAdd.call(req2, ctx.channel, [])

      # Remove
      req3 = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags", "member" => "elixir"})
      {:result, result, _} = Dust.MCP.Tools.DustRemove.call(req3, ctx.channel, [])

      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert text =~ "Removed"

      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "post.tags"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == ["rust"]
    end
  end

  describe "dust_rollback" do
    test "rolls back a path to a previous seq", ctx do
      # Write initial value
      put_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "title", "value" => "Hello"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      # Overwrite
      put_req2 =
        make_req(%{"store" => ctx.store_full_name, "path" => "title", "value" => "Changed"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req2, ctx.channel, [])

      # Rollback path to seq 1
      rb_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "title", "to_seq" => 1})

      {:result, result, _} = Dust.MCP.Tools.DustRollback.call(rb_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert text =~ "Rolled back title to seq 1"

      # Verify value was restored
      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "title"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == "Hello"
    end

    test "rolls back entire store", ctx do
      put_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "a", "value" => "1"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      put_req2 =
        make_req(%{"store" => ctx.store_full_name, "path" => "b", "value" => "2"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req2, ctx.channel, [])

      # Rollback to seq 1 (only "a" existed)
      rb_req = make_req(%{"store" => ctx.store_full_name, "to_seq" => 1})
      {:result, result, _} = Dust.MCP.Tools.DustRollback.call(rb_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = result
      assert text =~ "1 ops written"

      # "b" should be gone
      get_req = make_req(%{"store" => ctx.store_full_name, "path" => "b"})
      {:result, get_result, _} = Dust.MCP.Tools.DustGet.call(get_req, ctx.channel, [])
      assert %MCP.CallToolResult{content: [%MCP.TextContent{text: text}]} = get_result
      assert Jason.decode!(text) == nil
    end

    test "returns error for beyond retention", ctx do
      put_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "key", "value" => "v"})

      {:result, _, _} = Dust.MCP.Tools.DustPut.call(put_req, ctx.channel, [])

      rb_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "key", "to_seq" => 0})

      {:error, reason, _} = Dust.MCP.Tools.DustRollback.call(rb_req, ctx.channel, [])
      assert reason =~ "Rollback failed"
    end

    test "read-only token cannot rollback", ctx do
      {:ok, ro_token} =
        Dust.Stores.create_store_token(ctx.store, %{
          name: "readonly",
          read: true,
          write: false,
          created_by_id: ctx.token.created_by_id
        })

      {:ok, ro_token} = Dust.Stores.authenticate_token(ro_token.raw_token)

      ro_channel = %GenMCP.Mux.Channel{
        client: self(),
        progress_token: nil,
        status: :request,
        assigns: %{store_token: ro_token},
        log_level: :notice
      }

      rb_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "key", "to_seq" => 1})

      {:error, reason, _} = Dust.MCP.Tools.DustRollback.call(rb_req, ro_channel, [])
      assert reason =~ "write permission"
    end
  end

  describe "permission checks" do
    test "read-only token cannot write", ctx do
      # Create a read-only token
      {:ok, ro_token} =
        Dust.Stores.create_store_token(ctx.store, %{
          name: "readonly",
          read: true,
          write: false,
          created_by_id: ctx.token.created_by_id
        })

      # Need to re-authenticate to get the preloaded token
      {:ok, ro_token} = Dust.Stores.authenticate_token(ro_token.raw_token)

      ro_channel = %Channel{
        client: self(),
        progress_token: nil,
        status: :request,
        assigns: %{store_token: ro_token},
        log_level: :notice
      }

      put_req =
        make_req(%{"store" => ctx.store_full_name, "path" => "forbidden", "value" => "nope"})

      {:error, reason, _} = Dust.MCP.Tools.DustPut.call(put_req, ro_channel, [])
      assert reason =~ "write permission"
    end
  end
end
