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
