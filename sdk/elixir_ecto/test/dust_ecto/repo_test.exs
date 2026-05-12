defmodule DustEcto.RepoTest do
  use ExUnit.Case, async: false

  alias DustEcto.{Error, Repo}
  alias DustEcto.Test.{Link, FlatNote, MapLink}

  @store "myorg/mystore"

  setup do
    Application.put_env(:dust_ecto, :store, @store)
    Application.put_env(:dust_ecto, :base_url, "http://stub")
    Application.put_env(:dust_ecto, :token, "tok_test")
    Application.delete_env(:dust_ecto, :dust_facade)

    on_exit(fn ->
      Application.delete_env(:dust_ecto, :store)
      Application.delete_env(:dust_ecto, :base_url)
      Application.delete_env(:dust_ecto, :token)
      Application.delete_env(:dust_ecto, :req_plug)
    end)

    :ok
  end

  defp stub(handler) do
    stub_id = :"stub_#{System.unique_integer([:positive])}"
    Req.Test.stub(stub_id, handler)
    Application.put_env(:dust_ecto, :req_plug, {Req.Test, stub_id})
    :ok
  end

  defp valid_link_attrs(slug) do
    %{slug: slug, title: "T-#{slug}", url: "https://#{slug}", note: nil}
  end

  describe "all/1" do
    test "rebuilds records from leaf entries grouped by slug" do
      stub(fn conn ->
        # Two records: foo and bar.
        Req.Test.json(conn, %{
          "items" => [
            %{"path" => "links/foo/title", "value" => "Foo", "type" => "string", "revision" => 1},
            %{"path" => "links/foo/url", "value" => "https://foo", "type" => "string", "revision" => 2},
            %{"path" => "links/bar/title", "value" => "Bar", "type" => "string", "revision" => 3},
            %{"path" => "links/bar/url", "value" => "https://bar", "type" => "string", "revision" => 4}
          ],
          "next_cursor" => nil
        })
      end)

      assert {:ok, records} = Repo.all(Link)
      assert length(records) == 2

      slugs = records |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ["bar", "foo"]
    end

    test "skips records that fail required-fields guard, logs a warning" do
      stub(fn conn ->
        # foo has both required fields; bar is missing :url.
        Req.Test.json(conn, %{
          "items" => [
            %{"path" => "links/foo/title", "value" => "Foo", "type" => "string", "revision" => 1},
            %{"path" => "links/foo/url", "value" => "https://foo", "type" => "string", "revision" => 2},
            %{"path" => "links/bar/title", "value" => "Bar", "type" => "string", "revision" => 3}
          ],
          "next_cursor" => nil
        })
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, records} = Repo.all(Link)
          assert [%Link{slug: "foo"}] = records
        end)

      assert log =~ "skipping"
      assert log =~ "bar"
    end

    test "walks pages until next_cursor is nil" do
      page_count = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(page_count, 1, 1)
        n = :counters.get(page_count, 1)

        body =
          case n do
            1 ->
              %{
                "items" => [
                  %{"path" => "links/a/title", "value" => "A", "type" => "string", "revision" => 1},
                  %{"path" => "links/a/url", "value" => "u", "type" => "string", "revision" => 1}
                ],
                "next_cursor" => "links/a/url"
              }

            _ ->
              %{
                "items" => [
                  %{"path" => "links/b/title", "value" => "B", "type" => "string", "revision" => 2},
                  %{"path" => "links/b/url", "value" => "u", "type" => "string", "revision" => 2}
                ],
                "next_cursor" => nil
              }
          end

        Req.Test.json(conn, body)
      end)

      assert {:ok, records} = Repo.all(Link)
      assert length(records) == 2
      assert :counters.get(page_count, 1) == 2
    end
  end

  describe "get/2" do
    test "returns an assembled record on hit" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "path" => "links/foo",
          "value" => %{"title" => "Foo", "url" => "https://foo", "note" => nil},
          "type" => "map",
          "revision" => 5
        })
      end)

      assert {:ok, %Link{slug: "foo", title: "Foo", url: "https://foo"}} =
               Repo.get(Link, "foo")
    end

    test "returns {:error, :not_found} on 404" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
      assert {:error, :not_found} = Repo.get(Link, "missing")
    end
  end

  describe "get!/2" do
    test "raises on missing record" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)

      assert_raise RuntimeError, ~r/no DustEcto.Test.Link found/, fn ->
        Repo.get!(Link, "missing")
      end
    end
  end

  describe "exists?/2" do
    test "delegates to transport.exists?" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      assert {:ok, true} = Repo.exists?(Link, "foo")
    end
  end

  describe "insert/1 — flat mode (default)" do
    test "one PUT per non-nil field; :slug never written" do
      paths_called = :ets.new(:paths, [:public, :set, :named_table])
      :ets.insert(paths_called, {:paths, []})

      stub(fn conn ->
        [{:paths, paths}] = :ets.lookup(paths_called, :paths)
        :ets.insert(paths_called, {:paths, [conn.request_path | paths]})

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        # :slug must NOT appear in any field-write body
        refute String.contains?(body, "\"slug\"")

        Req.Test.json(conn, %{"store_seq" => 1})
      end)

      cs = Link.changeset(%Link{}, valid_link_attrs("foo"))
      assert {:ok, %Link{slug: "foo"}} = Repo.insert(cs)

      [{:paths, paths}] = :ets.lookup(paths_called, :paths)
      sorted = Enum.sort(paths)
      # Every declared field gets a PUT in flat mode — including nil-valued
      # ones (written as JSON null). :slug is the primary key and is never
      # written. :note and :added_at are nil in valid_link_attrs/1 but still
      # get a write per dust_ecto's "nil is a deliberate value" contract.
      assert sorted == [
               "/api/stores/myorg/mystore/entries/links/foo/added_at",
               "/api/stores/myorg/mystore/entries/links/foo/note",
               "/api/stores/myorg/mystore/entries/links/foo/title",
               "/api/stores/myorg/mystore/entries/links/foo/url"
             ]
    after
      try do
        :ets.delete(:paths)
      catch
        :error, :badarg -> :ok
      end
    end

    test "returns {:error, %Ecto.Changeset{}} on validation failure" do
      cs = Link.changeset(%Link{}, %{slug: "x"})
      # No transport call expected — validation fails first.
      assert {:error, %Ecto.Changeset{valid?: false}} = Repo.insert(cs)
    end

    test "narrow flat-mode covering exactly one field write" do
      paths_called = :ets.new(:paths2, [:public, :set, :named_table])
      :ets.insert(paths_called, {:paths, []})

      stub(fn conn ->
        [{:paths, paths}] = :ets.lookup(paths_called, :paths)
        :ets.insert(paths_called, {:paths, [conn.request_path | paths]})
        Req.Test.json(conn, %{"store_seq" => 1})
      end)

      cs = FlatNote.changeset(%FlatNote{}, %{slug: "x", body: "hi"})
      assert {:ok, %FlatNote{slug: "x"}} = Repo.insert(cs)

      [{:paths, paths}] = :ets.lookup(paths_called, :paths)
      assert paths == ["/api/stores/myorg/mystore/entries/notes/x/body"]
    after
      try do
        :ets.delete(:paths2)
      catch
        :error, :badarg -> :ok
      end
    end
  end

  describe "insert/1 — map mode (opt-in)" do
    test "single PUT at <prefix>.<slug> with the dumped struct" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/map_links/foo"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = JSON.decode!(body)
        # :slug must NOT be in the body
        refute Map.has_key?(decoded, "slug")
        assert decoded["title"] == "T-foo"
        assert decoded["url"] == "https://foo"

        Req.Test.json(conn, %{"store_seq" => 7})
      end)

      cs = MapLink.changeset(%MapLink{}, valid_link_attrs("foo"))
      assert {:ok, %MapLink{slug: "foo"}} = Repo.insert(cs)
    end
  end

  describe "subscribe/2 (HTTP mode)" do
    test "returns {:error, :not_supported} from the HTTP transport" do
      assert {:error, %Error{kind: :not_supported}} =
               Repo.subscribe(Link, fn _ -> :ok end)
    end
  end

  describe "all/1 — path reassembly edge cases" do
    test "handles dotted prefixes like 'reading.links'" do
      alias DustEcto.Test.DottedPrefixLink

      stub(fn conn ->
        Req.Test.json(conn, %{
          "items" => [
            %{"path" => "reading/links/foo/title", "value" => "Foo", "type" => "string", "revision" => 1}
          ],
          "next_cursor" => nil
        })
      end)

      assert {:ok, [%DottedPrefixLink{slug: "foo", title: "Foo"}]} =
               Repo.all(DottedPrefixLink)
    end

    test "reassembles nested map fields from server-flattened leaves" do
      alias DustEcto.Test.NestedThing

      stub(fn conn ->
        Req.Test.json(conn, %{
          "items" => [
            %{"path" => "things/foo/meta/a", "value" => 1, "type" => "integer", "revision" => 1},
            %{"path" => "things/foo/meta/b", "value" => 2, "type" => "integer", "revision" => 2}
          ],
          "next_cursor" => nil
        })
      end)

      assert {:ok, [%NestedThing{slug: "foo", meta: %{"a" => 1, "b" => 2}}]} =
               Repo.all(NestedThing)
    end
  end

  describe "stream/1" do
    test "raises on transport error rather than silently truncating" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end)

      assert_raise RuntimeError, ~r/transport error/, fn ->
        Link |> Repo.stream() |> Enum.to_list()
      end
    end

    test "yields records across pages until next_cursor is nil" do
      page_count = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(page_count, 1, 1)
        n = :counters.get(page_count, 1)

        body =
          if n == 1 do
            %{
              "items" => [
                %{"path" => "links/a/title", "value" => "A", "type" => "string", "revision" => 1},
                %{"path" => "links/a/url", "value" => "u", "type" => "string", "revision" => 1}
              ],
              "next_cursor" => "links/a/url"
            }
          else
            %{
              "items" => [
                %{"path" => "links/b/title", "value" => "B", "type" => "string", "revision" => 2},
                %{"path" => "links/b/url", "value" => "u", "type" => "string", "revision" => 2}
              ],
              "next_cursor" => nil
            }
          end

        Req.Test.json(conn, body)
      end)

      slugs = Link |> Repo.stream() |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ["a", "b"]
      assert :counters.get(page_count, 1) == 2
    end
  end

  describe "exists?/2 (HTTP transport)" do
    test "405 falls back to keys/limit=1 query" do
      requests = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(requests, 1, 1)

        cond do
          conn.method == "HEAD" ->
            Plug.Conn.send_resp(conn, 405, "")

          conn.method == "GET" and conn.request_path =~ ~r{/entries$} ->
            params = URI.decode_query(conn.query_string)
            assert params["select"] == "keys"
            assert params["limit"] == "1"

            Req.Test.json(conn, %{"items" => ["links/foo/title"], "next_cursor" => nil})
        end
      end)

      assert {:ok, true} = Repo.exists?(Link, "foo")
      assert :counters.get(requests, 1) == 2
    end

    test "405 with no matching keys returns false" do
      stub(fn conn ->
        cond do
          conn.method == "HEAD" ->
            Plug.Conn.send_resp(conn, 405, "")

          conn.method == "GET" ->
            Req.Test.json(conn, %{"items" => [], "next_cursor" => nil})
        end
      end)

      assert {:ok, false} = Repo.exists?(Link, "no-such")
    end
  end

  describe "update/2 — :if_match plumbing" do
    test ":map mode forwards if_match to the single PUT" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/map_links/foo"
        assert {"if-match", "7"} in conn.req_headers
        Req.Test.json(conn, %{"store_seq" => 8})
      end)

      cs =
        %MapLink{slug: "foo", title: "T", url: "U"}
        |> MapLink.changeset(%{title: "T2"})

      assert {:ok, %MapLink{title: "T2"}} = Repo.update(cs, if_match: 7)
    end

    test ":map mode surfaces a 412 conflict as %Error{kind: :conflict}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(412, ~s({"error":"conflict","current_revision":99}))
      end)

      cs =
        %MapLink{slug: "foo", title: "T", url: "U"}
        |> MapLink.changeset(%{title: "T2"})

      assert {:error, %Error{kind: :conflict, detail: %{current_revision: 99}}} =
               Repo.update(cs, if_match: 1)
    end

    test ":flat mode raises on if_match" do
      cs =
        %Link{slug: "foo", title: "T", url: "U"}
        |> Link.changeset(%{title: "T2"})

      assert_raise ArgumentError, ~r/:if_match is only supported on :map-mode/, fn ->
        Repo.update(cs, if_match: 7)
      end
    end
  end

  describe "delete — :if_match plumbing" do
    test "delete(schema, slug, if_match: n) forwards the header" do
      stub(fn conn ->
        assert conn.method == "DELETE"
        assert {"if-match", "4"} in conn.req_headers
        Req.Test.json(conn, %{"store_seq" => 5})
      end)

      assert {:ok, %{store_seq: 5}} = Repo.delete(Link, "foo", if_match: 4)
    end

    test "delete(struct, if_match: n) forwards the header" do
      stub(fn conn ->
        assert {"if-match", "9"} in conn.req_headers
        Req.Test.json(conn, %{"store_seq" => 10})
      end)

      assert {:ok, _} = Repo.delete(%Link{slug: "foo"}, if_match: 9)
    end

    test "delete(schema, slug) without opts sends no if-match header" do
      stub(fn conn ->
        refute Enum.any?(conn.req_headers, fn {k, _} -> k == "if-match" end)
        Req.Test.json(conn, %{"store_seq" => 1})
      end)

      assert {:ok, _} = Repo.delete(Link, "foo")
    end
  end

  describe "batch_write/1" do
    test ":map-mode insert + :map-mode delete in one commit" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/batch_write"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = JSON.decode!(body)

        # Two ops in the batch, in the order submitted. Paths in the
        # batch_write body are dotted (canonical) — only URL segments use
        # slashes.
        assert [%{"op" => "set", "path" => "map_links/foo"}, %{"op" => "delete", "path" => "map_links/bar"}] =
                 Enum.map(decoded["ops"], &Map.take(&1, ["op", "path"]))

        Req.Test.json(conn, %{
          "store_seq" => 42,
          "ops" => [
            %{"path" => "map_links/foo", "store_seq" => 41, "revision" => 41},
            %{"path" => "map_links/bar", "store_seq" => 42, "revision" => 42}
          ]
        })
      end)

      cs = MapLink.changeset(%MapLink{}, valid_link_attrs("foo"))

      assert {:ok, %{store_seq: 42, ops: ops_out}} =
               Repo.batch_write([
                 {:insert, cs},
                 {:delete, MapLink, "bar"}
               ])

      assert length(ops_out) == 2
    end

    test ":flat-mode insert expands to N ops (one per non-nil field)" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = JSON.decode!(body)

        # FlatNote has exactly one writable field, :body.
        assert [%{"op" => "set", "path" => "notes/x/body", "value" => "hi"}] = decoded["ops"]

        Req.Test.json(conn, %{
          "store_seq" => 1,
          "ops" => [%{"path" => "notes/x/body", "store_seq" => 1, "revision" => 1}]
        })
      end)

      cs = FlatNote.changeset(%FlatNote{}, %{slug: "x", body: "hi"})
      assert {:ok, _} = Repo.batch_write([{:insert, cs}])
    end

    test ":map-mode insert with :if_match forwards the per-op revision" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = JSON.decode!(body)

        assert [%{"if_match" => 7}] = decoded["ops"]

        Req.Test.json(conn, %{"store_seq" => 8, "ops" => []})
      end)

      cs = MapLink.changeset(%MapLink{}, valid_link_attrs("foo"))
      assert {:ok, _} = Repo.batch_write([{:insert, cs, if_match: 7}])
    end

    test ":flat-mode insert with :if_match raises" do
      cs = FlatNote.changeset(%FlatNote{}, %{slug: "x", body: "hi"})

      assert_raise ArgumentError, ~r/:if_match is not supported on :flat-mode/, fn ->
        Repo.batch_write([{:insert, cs, if_match: 7}])
      end
    end

    test "short-circuits with {:error, %Ecto.Changeset{}} on validation failure" do
      bad = MapLink.changeset(%MapLink{}, %{slug: ""})

      assert {:error, %Ecto.Changeset{valid?: false}} = Repo.batch_write([{:insert, bad}])
    end

    test "rejects unrecognised op tuples with %Error{kind: :invalid_params}" do
      assert {:error, %Error{kind: :invalid_params}} =
               Repo.batch_write([{:wat, :unrecognised}])
    end
  end

  describe "404 error translation" do
    test "whole-route 404 on DELETE surfaces as :not_implemented" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(404, "Not Found")
      end)

      assert {:error, %Error{kind: :not_implemented, detail: %{status: 404}}} =
               Repo.delete(Link, "anything")
    end
  end

  describe "delete/1 + delete/2 + delete_all/1" do
    test "delete(struct) hits DELETE /entries/<prefix>/<slug>" do
      stub(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/links/foo"
        Req.Test.json(conn, %{"store_seq" => 9})
      end)

      assert {:ok, %{store_seq: 9}} = Repo.delete(%Link{slug: "foo"})
    end

    test "delete(schema, slug) is the convenience form" do
      stub(fn conn ->
        assert conn.request_path == "/api/stores/myorg/mystore/entries/links/foo"
        Req.Test.json(conn, %{"store_seq" => 9})
      end)

      assert {:ok, %{store_seq: 9}} = Repo.delete(Link, "foo")
    end

    test "delete_all(schema) DELETEs the bare prefix" do
      stub(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/links"
        Req.Test.json(conn, %{"store_seq" => 100})
      end)

      assert {:ok, %{store_seq: 100}} = Repo.delete_all(Link)
    end
  end
end
