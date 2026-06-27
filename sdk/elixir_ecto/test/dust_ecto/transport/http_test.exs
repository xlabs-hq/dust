defmodule DustEcto.Transport.HTTPTest do
  use ExUnit.Case, async: false

  alias DustEcto.Error
  alias DustEcto.Transport.HTTP

  @store "myorg/mystore"

  setup do
    Application.put_env(:dustlayer_ecto, :store, @store)
    Application.put_env(:dustlayer_ecto, :base_url, "http://stub")
    Application.put_env(:dustlayer_ecto, :token, "tok_test")
    Application.delete_env(:dustlayer_ecto, :dust_facade)

    on_exit(fn ->
      Application.delete_env(:dustlayer_ecto, :store)
      Application.delete_env(:dustlayer_ecto, :base_url)
      Application.delete_env(:dustlayer_ecto, :token)
      Application.delete_env(:dustlayer_ecto, :req_plug)
    end)

    :ok
  end

  defp stub(handler) do
    stub_id = :"stub_#{System.unique_integer([:positive])}"
    Req.Test.stub(stub_id, handler)
    Application.put_env(:dustlayer_ecto, :req_plug, {Req.Test, stub_id})
    :ok
  end

  describe "list/3" do
    test "GETs /entries with pattern + limit, decodes JSON body" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/stores/myorg/mystore/entries"
        params = URI.decode_query(conn.query_string)
        assert params["pattern"] == "links/**"
        assert params["limit"] == "50"
        assert params["select"] == "entries"

        Req.Test.json(conn, %{
          "items" => [
            %{"path" => "links/foo/title", "value" => "Foo", "type" => "string", "revision" => 5}
          ],
          "next_cursor" => "links/foo/title"
        })
      end)

      assert {:ok, page} = HTTP.list(@store, "links/**", limit: 50, select: :entries)
      assert page.next_cursor == "links/foo/title"
      assert [%{path: "links/foo/title", value: "Foo", revision: 5}] = page.items
    end
  end

  describe "get/2" do
    test "200 returns the entry" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/links/foo/title"

        Req.Test.json(conn, %{
          "path" => "links/foo/title",
          "value" => "Foo",
          "type" => "string",
          "revision" => 7
        })
      end)

      assert {:ok, entry} = HTTP.get(@store, "links/foo/title")
      assert entry.path == "links/foo/title"
      assert entry.revision == 7
    end

    test "404 status maps to {:error, :not_found}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"error":"not_found"}))
      end)

      assert {:error, :not_found} = HTTP.get(@store, "no/such/path")
    end
  end

  describe "exists?/2" do
    test "200 -> true" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      assert {:ok, true} = HTTP.exists?(@store, "x")
    end

    test "404 -> false" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      assert {:ok, false} = HTTP.exists?(@store, "no.such")
    end
  end

  describe "put/4" do
    test "PUT with JSON body returns {:ok, %{store_seq:}}" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/links/foo/title"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body) == "Foo"

        Req.Test.json(conn, %{"store_seq" => 42, "revision" => 42})
      end)

      assert {:ok, %{store_seq: 42}} = HTTP.put(@store, "links/foo/title", "Foo", [])
    end

    test "If-Match header is forwarded when provided in opts" do
      stub(fn conn ->
        assert {"if-match", "5"} in conn.req_headers
        Req.Test.json(conn, %{"store_seq" => 6})
      end)

      assert {:ok, %{store_seq: 6}} = HTTP.put(@store, "links/foo/title", "F", if_match: 5)
    end

    test "412 conflict translates to %Error{kind: :conflict}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          412,
          ~s({"error":"conflict","current_revision":3})
        )
      end)

      assert {:error, %Error{kind: :conflict, detail: %{current_revision: 3}}} =
               HTTP.put(@store, "k", "v", if_match: 99)
    end
  end

  describe "delete/3" do
    test "DELETE returns {:ok, %{store_seq:}}" do
      stub(fn conn ->
        assert conn.method == "DELETE"
        Req.Test.json(conn, %{"store_seq" => 99})
      end)

      assert {:ok, %{store_seq: 99}} = HTTP.delete(@store, "k", [])
    end
  end

  describe "batch_write/3" do
    test "POSTs ops list, returns {:ok, %{store_seq:, ops:}}" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/batch_write"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = JSON.decode!(body)
        assert length(decoded["ops"]) == 2

        Req.Test.json(conn, %{
          "store_seq" => 11,
          "ops" => [
            %{"path" => "a", "store_seq" => 10, "revision" => 10},
            %{"path" => "b", "store_seq" => 11, "revision" => 11}
          ]
        })
      end)

      ops = [
        %{op: :set, path: "a", value: 1},
        %{op: :delete, path: "b"}
      ]

      assert {:ok, %{store_seq: 11, ops: ops_out}} = HTTP.batch_write(@store, ops, [])
      assert length(ops_out) == 2
    end
  end

  describe "subscribe/3" do
    test "returns {:error, :not_supported} on HTTP transport" do
      assert {:error, %Error{kind: :not_supported}} =
               HTTP.subscribe(@store, "**", fn _ -> :ok end)
    end
  end

  describe "path encoding (RFC 3986 path segments, not query form)" do
    test "spaces become %20, not '+'" do
      stub(fn conn ->
        # The raw request path on the wire — RFC 3986 percent-encoding,
        # not www-form-urlencoded. A `+` here would be a Bug because
        # some HTTP layers treat it as a space.
        assert conn.request_path == "/api/stores/myorg/mystore/entries/hello%20world/title"
        refute conn.request_path =~ "+"

        Req.Test.json(conn, %{
          "path" => "hello world/title",
          "value" => "x",
          "type" => "string",
          "revision" => 1
        })
      end)

      assert {:ok, _} = HTTP.get(@store, "hello world/title")
    end

    test "literal '+' in a segment is percent-encoded" do
      stub(fn conn ->
        assert conn.request_path == "/api/stores/myorg/mystore/entries/a%2Bb"

        Req.Test.json(conn, %{
          "path" => "a+b",
          "value" => "x",
          "type" => "string",
          "revision" => 1
        })
      end)

      assert {:ok, _} = HTTP.get(@store, "a+b")
    end

    test "~1 (literal '/' in a segment) is sent intact, not as %2F" do
      # Canonical path "files/image~1logo" encodes a single logical
      # segment "image/logo" — the `~1` must survive into the URL or
      # the server splits it back into two segments.
      stub(fn conn ->
        assert conn.request_path == "/api/stores/myorg/mystore/entries/files/image~1logo"
        refute conn.request_path =~ "%2F"

        Req.Test.json(conn, %{
          "path" => "files/image~1logo",
          "value" => "blob",
          "type" => "string",
          "revision" => 1
        })
      end)

      assert {:ok, _} = HTTP.get(@store, "files/image~1logo")
    end

    test "~0 (literal '~' in a segment) is sent intact" do
      stub(fn conn ->
        assert conn.request_path == "/api/stores/myorg/mystore/entries/files/image~0logo"

        Req.Test.json(conn, %{
          "path" => "files/image~0logo",
          "value" => "blob",
          "type" => "string",
          "revision" => 1
        })
      end)

      assert {:ok, _} = HTTP.get(@store, "files/image~0logo")
    end
  end

  describe "error translation" do
    test "401 -> :unauthorized" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({})) end)
      assert {:error, %Error{kind: :unauthorized}} = HTTP.get(@store, "k")
    end

    test "429 -> :rate_limited (retryable)" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, ~s({}))
      end)

      assert {:error, %Error{kind: :rate_limited, retryable?: true, detail: detail}} =
               HTTP.get(@store, "k")

      assert detail.retry_after == "30"
    end

    test "500 -> :http (retryable)" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, ~s({"error":"boom"})) end)
      assert {:error, %Error{kind: :http, retryable?: true}} = HTTP.get(@store, "k")
    end
  end
end
