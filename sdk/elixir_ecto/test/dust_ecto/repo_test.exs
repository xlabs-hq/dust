defmodule DustEcto.RepoTest do
  use ExUnit.Case, async: false

  alias DustEcto.{Error, Repo}
  alias DustEcto.Test.{Link, FlatNote}

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
            %{"path" => "links.foo.title", "value" => "Foo", "type" => "string", "revision" => 1},
            %{"path" => "links.foo.url", "value" => "https://foo", "type" => "string", "revision" => 2},
            %{"path" => "links.bar.title", "value" => "Bar", "type" => "string", "revision" => 3},
            %{"path" => "links.bar.url", "value" => "https://bar", "type" => "string", "revision" => 4}
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
            %{"path" => "links.foo.title", "value" => "Foo", "type" => "string", "revision" => 1},
            %{"path" => "links.foo.url", "value" => "https://foo", "type" => "string", "revision" => 2},
            %{"path" => "links.bar.title", "value" => "Bar", "type" => "string", "revision" => 3}
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
                  %{"path" => "links.a.title", "value" => "A", "type" => "string", "revision" => 1},
                  %{"path" => "links.a.url", "value" => "u", "type" => "string", "revision" => 1}
                ],
                "next_cursor" => "links.a.url"
              }

            _ ->
              %{
                "items" => [
                  %{"path" => "links.b.title", "value" => "B", "type" => "string", "revision" => 2},
                  %{"path" => "links.b.url", "value" => "u", "type" => "string", "revision" => 2}
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
          "path" => "links.foo",
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

  describe "insert/1 — map mode" do
    test "single PUT at <prefix>.<slug> with the dumped struct" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/stores/myorg/mystore/entries/links/foo"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = JSON.decode!(body)
        # :slug must NOT be in the body
        refute Map.has_key?(decoded, "slug")
        assert decoded["title"] == "T-foo"
        assert decoded["url"] == "https://foo"

        Req.Test.json(conn, %{"store_seq" => 7})
      end)

      cs = Link.changeset(%Link{}, valid_link_attrs("foo"))
      assert {:ok, %Link{slug: "foo"}} = Repo.insert(cs)
    end

    test "returns {:error, %Ecto.Changeset{}} on validation failure" do
      cs = Link.changeset(%Link{}, %{slug: "x"})
      # No transport call expected — validation fails first.
      assert {:error, %Ecto.Changeset{valid?: false}} = Repo.insert(cs)
    end
  end

  describe "insert/1 — flat mode" do
    test "one PUT per non-nil field; :slug never written" do
      paths_called = :ets.new(:paths, [:public, :set, :named_table])
      :ets.insert(paths_called, {:paths, []})

      stub(fn conn ->
        [{:paths, paths}] = :ets.lookup(paths_called, :paths)
        :ets.insert(paths_called, {:paths, [conn.request_path | paths]})
        Req.Test.json(conn, %{"store_seq" => 1})
      end)

      cs = FlatNote.changeset(%FlatNote{}, %{slug: "x", body: "hi"})
      assert {:ok, %FlatNote{slug: "x"}} = Repo.insert(cs)

      [{:paths, paths}] = :ets.lookup(paths_called, :paths)
      # Exactly one PUT to .body — :slug is the primary key, not a written field.
      assert paths == ["/api/stores/myorg/mystore/entries/notes/x/body"]
    after
      try do
        :ets.delete(:paths)
      catch
        :error, :badarg -> :ok
      end
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
            %{"path" => "reading.links.foo.title", "value" => "Foo", "type" => "string", "revision" => 1}
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
            %{"path" => "things.foo.meta.a", "value" => 1, "type" => "integer", "revision" => 1},
            %{"path" => "things.foo.meta.b", "value" => 2, "type" => "integer", "revision" => 2}
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
                %{"path" => "links.a.title", "value" => "A", "type" => "string", "revision" => 1},
                %{"path" => "links.a.url", "value" => "u", "type" => "string", "revision" => 1}
              ],
              "next_cursor" => "links.a.url"
            }
          else
            %{
              "items" => [
                %{"path" => "links.b.title", "value" => "B", "type" => "string", "revision" => 2},
                %{"path" => "links.b.url", "value" => "u", "type" => "string", "revision" => 2}
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

            Req.Test.json(conn, %{"items" => ["links.foo.title"], "next_cursor" => nil})
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
