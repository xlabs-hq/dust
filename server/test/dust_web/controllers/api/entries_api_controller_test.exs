defmodule DustWeb.Api.EntriesApiControllerTest do
  use DustWeb.ConnCase, async: false

  alias Dust.Accounts
  alias Dust.Stores
  alias Dust.Sync

  setup do
    store_dir = Application.get_env(:dust, :store_data_dir, "priv/stores")
    File.rm_rf!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, user} = Accounts.create_user(%{email: "entries-api@example.com"})

    {:ok, org} =
      Accounts.create_organization_with_owner(user, %{name: "Entries Org", slug: "entriesorg"})

    {:ok, store} = Stores.create_store(org, %{name: "mystore"})

    {:ok, token} =
      Stores.create_store_token(store, %{
        name: "entries-tok",
        read: true,
        write: true,
        created_by_id: user.id
      })

    seed_entry(store, "users.alice.email", "alice@example.com")
    seed_entry(store, "users.alice.name", "Alice")
    seed_entry(store, "users.bob.name", "Bob")

    %{org: org, store: store, token: token, user: user}
  end

  defp seed_entry(store, path, value) do
    {:ok, _op} =
      Sync.write(store.id, %{
        op: :set,
        path: path,
        value: value,
        device_id: "test-device",
        client_op_id: "seed-#{path}"
      })
  end

  defp api_conn(conn, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token.raw_token}")
  end

  describe "GET /api/stores/:org/:store/entries" do
    test "returns paginated entries with revision field", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&limit=10")

      body = json_response(resp, 200)
      assert length(body["items"]) == 3

      first = hd(body["items"])
      assert first["path"] =~ "users."
      assert is_integer(first["revision"])
      assert Map.has_key?(first, "value")
      assert Map.has_key?(first, "type")
      assert body["next_cursor"] == nil
    end

    test "select=keys returns list of path strings", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&select=keys")

      body = json_response(resp, 200)

      assert body["items"] == [
               "users.alice.email",
               "users.alice.name",
               "users.bob.name"
             ]
    end

    test "select=prefixes with valid pattern returns unique next-segment prefixes", %{
      conn: conn,
      token: token
    } do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&select=prefixes")

      body = json_response(resp, 200)
      assert body["items"] == ["users.alice", "users.bob"]
    end

    test "select=prefixes with invalid pattern returns 400 with detail", %{
      conn: conn,
      token: token
    } do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.*&select=prefixes")

      body = json_response(resp, 400)
      assert body["error"] == "invalid_pattern_for_prefixes"
      assert is_binary(body["detail"])
      assert body["detail"] =~ "**"
      assert body["detail"] =~ "<base>.**"
    end

    test "paginates via next_cursor with limit=1", %{conn: conn, token: token} do
      resp1 =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&select=keys&limit=1")

      body1 = json_response(resp1, 200)
      assert length(body1["items"]) == 1
      assert body1["next_cursor"] != nil

      resp2 =
        conn
        |> api_conn(token)
        |> get(
          "/api/stores/entriesorg/mystore/entries?pattern=users.**&select=keys&limit=1&after=#{body1["next_cursor"]}"
        )

      body2 = json_response(resp2, 200)
      assert length(body2["items"]) == 1
      assert body2["items"] != body1["items"]
    end

    test "returns 401 without Bearer token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/stores/entriesorg/mystore/entries?pattern=**")

      assert resp.status == 401
    end

    test "paginates narrow glob over wide raw prefix without dropping matches", %{
      conn: conn,
      token: token,
      store: store
    } do
      # Seed 60 decoy entries under logs.server.alpha.NNN. These sort LEXICALLY
      # BEFORE "logs.server.error.*" so a naive limit+1 raw fetch captures 51
      # alpha rows, zero matches, and returns {[], nil} with the bug.
      for i <- 1..60 do
        suffix = String.pad_leading(to_string(i), 3, "0")
        seed_entry(store, "logs.server.alpha.#{suffix}", "alpha-#{suffix}")
      end

      # Seed 3 entries that actually match the narrow glob
      for i <- 1..3 do
        seed_entry(store, "logs.server.error.#{i}", "error-#{i}")
      end

      # Walk pages following next_cursor until exhausted.
      # With the bug, the raw LIKE window "logs.%" hits 51 rows before we ever
      # see an error row if the ordering happens to surface info.* first; on
      # :desc order the error rows come first but we must still walk without
      # getting a spurious early nil next_cursor.
      pattern = "logs.*.error.**"

      walk = fn conn, token, walk ->
        fn after_cursor, acc, pages ->
          url =
            "/api/stores/entriesorg/mystore/entries?pattern=#{pattern}&select=keys&limit=50" <>
              if after_cursor, do: "&after=#{URI.encode(after_cursor)}", else: ""

          resp = conn |> api_conn(token) |> get(url)
          body = json_response(resp, 200)
          new_acc = acc ++ body["items"]

          case body["next_cursor"] do
            nil -> {new_acc, pages + 1}
            cursor -> walk.(conn, token, walk).(cursor, new_acc, pages + 1)
          end
        end
      end

      {all_items, page_count} = walk.(conn, token, walk).(nil, [], 0)

      assert Enum.sort(all_items) == [
               "logs.server.error.1",
               "logs.server.error.2",
               "logs.server.error.3"
             ]

      assert page_count <= 2
    end

    test "I1 regression: literal '%' in pattern prefix returns only exact matches", %{
      conn: conn,
      token: token,
      store: store
    } do
      # Seed an entry whose literal prefix contains '%'
      seed_entry(store, "weird%.child", "match-me")
      # Decoy that an unescaped LIKE 'weird%.%' would also capture
      seed_entry(store, "weirdX.child", "decoy")

      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=weird%25.**&select=keys")

      body = json_response(resp, 200)
      assert body["items"] == ["weird%.child"]
    end
  end

  describe "GET /api/stores/:org/:store/entries range mode" do
    setup %{store: store} do
      # Seed a..f as top-level entries for range tests.
      for letter <- ~w(a b c d e f) do
        seed_entry(store, letter, "val-#{letter}")
      end

      :ok
    end

    test "GET /entries?from=b&to=e returns items in lexicographic range with revision",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?from=b&to=e")

      body = json_response(resp, 200)
      assert Enum.map(body["items"], & &1["path"]) == ~w(b c d)

      first = hd(body["items"])
      assert is_integer(first["revision"])
      assert Map.has_key?(first, "value")
      assert Map.has_key?(first, "type")
      assert body["next_cursor"] == nil
    end

    test "GET /entries?from=b&to=e&select=keys returns path strings only",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?from=b&to=e&select=keys")

      body = json_response(resp, 200)
      assert body["items"] == ~w(b c d)
    end

    test "GET /entries?from=b&to=e&select=prefixes returns 400 unsupported_select",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?from=b&to=e&select=prefixes")

      body = json_response(resp, 400)
      assert body["error"] == "unsupported_select"
      assert body["detail"] == "select=prefixes not supported for range"
    end

    test "GET /entries with both pattern and from returns 400 conflicting_params",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.**&from=a&to=z")

      body = json_response(resp, 400)
      assert body["error"] == "conflicting_params"
      assert body["detail"] == "use either pattern or from/to, not both"
    end

    test "GET /entries?from=a (no to) returns 400 invalid_params",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?from=a")

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] == "from requires to"
    end

    test "GET /entries?to=z (no from) returns 400 invalid_params",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?to=z")

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] == "to requires from"
    end

    test "range pagination via next_cursor works across two pages",
         %{conn: conn, token: token} do
      resp1 =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?from=a&to=g&select=keys&limit=2")

      body1 = json_response(resp1, 200)
      assert body1["items"] == ~w(a b)
      assert body1["next_cursor"] != nil

      resp2 =
        conn
        |> api_conn(token)
        |> get(
          "/api/stores/entriesorg/mystore/entries?from=a&to=g&select=keys&limit=2&after=#{URI.encode(body1["next_cursor"])}"
        )

      body2 = json_response(resp2, 200)
      assert body2["items"] == ~w(c d)
      assert body2["next_cursor"] != nil
    end

    test "range with order=desc returns reversed items",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?from=b&to=e&select=keys&order=desc")

      body = json_response(resp, 200)
      assert body["items"] == ~w(d c b)
    end
  end

  describe "POST /api/stores/:org/:store/entries/batch" do
    test "returns rich envelope with entries and missing for mixed paths", %{
      conn: conn,
      token: token
    } do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch",
          Jason.encode!(%{
            "paths" => [
              "users.alice.email",
              "users.alice.name",
              "users.nope",
              "totally.absent"
            ]
          })
        )

      body = json_response(resp, 200)

      assert Map.keys(body["entries"]) |> Enum.sort() == [
               "users.alice.email",
               "users.alice.name"
             ]

      alice_email = body["entries"]["users.alice.email"]
      assert alice_email["value"] == "alice@example.com"
      assert is_binary(alice_email["type"])
      assert is_integer(alice_email["revision"])

      assert Enum.sort(body["missing"]) == ["totally.absent", "users.nope"]
    end

    test "empty paths list returns empty envelope", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch",
          Jason.encode!(%{"paths" => []})
        )

      body = json_response(resp, 200)
      assert body == %{"entries" => %{}, "missing" => []}
    end

    test "missing paths key returns 400 invalid_params", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch",
          Jason.encode!(%{})
        )

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] == "paths required"
    end

    test "more than 1000 paths returns 400 invalid_params", %{conn: conn, token: token} do
      paths = for i <- 1..1001, do: "p#{i}"

      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch",
          Jason.encode!(%{"paths" => paths})
        )

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] == "maximum 1000 paths per batch"
    end

    test "non-string element in paths returns 400 invalid_params", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch",
          Jason.encode!(%{"paths" => ["users.alice.name", 42]})
        )

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] == "paths must be strings"
    end

    test "returns 401 without Bearer token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch",
          Jason.encode!(%{"paths" => ["users.alice.name"]})
        )

      assert resp.status == 401
    end

    test "GET /entries/batch (wrong method) still hits wildcard show route", %{
      conn: conn,
      token: token
    } do
      # Regression: confirm POST /entries/batch route does not break the
      # wildcard GET /entries/*path. A GET to /entries/batch should fall
      # through to :show, where "batch" is a non-existent path => 404.
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries/batch")

      assert json_response(resp, 404) == %{"error" => "not_found"}
    end
  end

  describe "GET /api/stores/:org/:store/entries/*path" do
    test "returns 200 with path, value, type, and integer revision for a leaf entry", %{
      conn: conn,
      token: token
    } do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries/users/alice/name")

      body = json_response(resp, 200)
      assert body["path"] == "users.alice.name"
      assert body["value"] == "Alice"
      assert is_binary(body["type"])
      assert is_integer(body["revision"])
    end

    test "returns 404 for a path that does not exist", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries/no/such/path")

      assert json_response(resp, 404) == %{"error" => "not_found"}
    end

    # Parent-path behavior: `Dust.Sync.get_entry/2` returns an assembled subtree
    # map when the requested path has no leaf but has descendants (see
    # `assemble_subtree/2` in `lib/dust/sync.ex`). The plan allows either a 200
    # with a subtree or a 404; the server natively returns the subtree so the
    # HTTP endpoint exposes it. This test asserts the 200-subtree behavior.
    test "returns 200 with an assembled subtree for a parent path", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries/users")

      body = json_response(resp, 200)
      assert body["path"] == "users"
      assert body["type"] == "map"
      assert is_integer(body["revision"])

      assert body["value"] == %{
               "alice" => %{"email" => "alice@example.com", "name" => "Alice"},
               "bob" => %{"name" => "Bob"}
             }
    end

    test "returns 401 without Bearer token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/stores/entriesorg/mystore/entries/users/alice/name")

      assert resp.status == 401
    end
  end

  describe "PUT /api/stores/:org/:store/entries/*path" do
    test "writes a leaf value without If-Match (LWW)", %{conn: conn, token: token, store: store} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put(
          "/api/stores/entriesorg/mystore/entries/users/alice/name",
          ~s("Alice Updated")
        )

      body = json_response(resp, 200)
      assert is_integer(body["revision"])
      assert body["revision"] == body["store_seq"]

      # Verify the value was actually written.
      assert %{value: "Alice Updated"} = Sync.get_entry(store.id, "users.alice.name")
    end

    test "PUT with empty body returns 400 with hint about JSON null and DELETE", %{
      conn: conn,
      token: token
    } do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put("/api/stores/entriesorg/mystore/entries/users/alice/name", "")

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] =~ "null"
      assert body["detail"] =~ "DELETE"
    end

    test "writes a leaf value with matching If-Match succeeds", %{
      conn: conn,
      token: token,
      store: store
    } do
      seed_entry(store, "cas.counter", 1)
      %{seq: seq} = Sync.get_entry(store.id, "cas.counter")

      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-match", Integer.to_string(seq))
        |> put("/api/stores/entriesorg/mystore/entries/cas/counter", "2")

      body = json_response(resp, 200)
      assert body["revision"] > seq

      assert %{value: 2} = Sync.get_entry(store.id, "cas.counter")
    end

    test "stale If-Match returns 412 with current_revision", %{
      conn: conn,
      token: token,
      store: store
    } do
      seed_entry(store, "cas.counter", 1)
      %{seq: seq} = Sync.get_entry(store.id, "cas.counter")

      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-match", "999999")
        |> put("/api/stores/entriesorg/mystore/entries/cas/counter", "2")

      body = json_response(resp, 412)
      assert body["error"] == "conflict"
      assert body["current_revision"] == seq

      # Entry is unchanged.
      assert %{value: 1} = Sync.get_entry(store.id, "cas.counter")
    end

    test "If-Match with dict body returns 400 if_match_multi_leaf", %{
      conn: conn,
      token: token,
      store: store
    } do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-match", "5")
        |> put(
          "/api/stores/entriesorg/mystore/entries/users/alice",
          ~s({"name": "Alice"})
        )

      body = json_response(resp, 400)
      assert body["error"] == "if_match_multi_leaf"
      assert is_binary(body["detail"])

      # The existing subtree is unchanged (safety invariant preserved).
      assert %{value: "Alice"} = Sync.get_entry(store.id, "users.alice.name")
    end

    test "returns 401 without Bearer token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put("/api/stores/entriesorg/mystore/entries/cas/counter", "1")

      assert resp.status == 401
    end
  end

  describe "POST /api/stores/:org/:store/entries/batch_write" do
    defp batch_write_post(conn, token, body) do
      conn
      |> api_conn(token)
      |> put_req_header("content-type", "application/json")
      |> post("/api/stores/entriesorg/mystore/entries/batch_write", body)
    end

    test "applies all ops atomically", %{conn: conn, token: token, store: store} do
      body = %{
        ops: [
          %{op: "set", path: "links/foo/title", value: "Foo"},
          %{op: "set", path: "links/foo/url", value: "https://foo"},
          %{op: "delete", path: "users/bob/name"}
        ]
      }

      resp = batch_write_post(conn, token, Jason.encode!(body))
      result = json_response(resp, 200)

      assert length(result["ops"]) == 3
      assert is_integer(result["store_seq"])

      # All three writes landed.
      assert %{value: "Foo"} = Sync.get_entry(store.id, "links.foo.title")
      assert %{value: "https://foo"} = Sync.get_entry(store.id, "links.foo.url")
      assert Sync.get_entry(store.id, "users.bob.name") == nil

      # store_seq is monotonic across the batch.
      [op1, op2, op3] = result["ops"]
      assert op1["store_seq"] < op2["store_seq"]
      assert op2["store_seq"] < op3["store_seq"]
    end

    test "rolls back the whole batch on a CAS conflict", %{
      conn: conn,
      token: token,
      store: store
    } do
      seed_entry(store, "cas.counter", 1)

      body = %{
        ops: [
          %{op: "set", path: "batch/a", value: "a"},
          %{op: "set", path: "cas/counter", value: 999, if_match: 999_999},
          %{op: "set", path: "batch/b", value: "b"}
        ]
      }

      resp = batch_write_post(conn, token, Jason.encode!(body))
      err = json_response(resp, 412)

      assert err["error"] == "conflict"
      assert err["op_index"] == 1
      assert err["path"] == "cas.counter"
      assert is_integer(err["current_revision"])

      # No ops applied — first and third writes did not land.
      assert Sync.get_entry(store.id, "batch.a") == nil
      assert Sync.get_entry(store.id, "batch.b") == nil
      assert %{value: 1} = Sync.get_entry(store.id, "cas.counter")
    end

    test "returns 400 if_match_multi_leaf for a multi-key map with If-Match", %{
      conn: conn,
      token: token,
      store: store
    } do
      body = %{
        ops: [
          %{op: "set", path: "batch/a", value: "a"},
          %{op: "set", path: "batch/multi", value: %{x: 1, y: 2}, if_match: 5}
        ]
      }

      resp = batch_write_post(conn, token, Jason.encode!(body))
      err = json_response(resp, 400)
      assert err["error"] == "if_match_multi_leaf"
      assert err["op_index"] == 1

      # No ops applied.
      assert Sync.get_entry(store.id, "batch.a") == nil
    end

    test "rejects empty ops list", %{conn: conn, token: token} do
      resp = batch_write_post(conn, token, Jason.encode!(%{ops: []}))
      err = json_response(resp, 400)
      assert err["error"] == "invalid_params"
      assert err["detail"] =~ "empty"
    end

    test "rejects > 1000 ops", %{conn: conn, token: token} do
      ops = for i <- 1..1001, do: %{op: "set", path: "batch/k#{i}", value: i}
      resp = batch_write_post(conn, token, Jason.encode!(%{ops: ops}))
      err = json_response(resp, 400)
      assert err["error"] == "invalid_params"
      assert err["detail"] =~ "1000"
    end

    test "rejects unknown op kind", %{conn: conn, token: token} do
      body = %{ops: [%{op: "merge", path: "x", value: %{}}]}
      resp = batch_write_post(conn, token, Jason.encode!(body))
      err = json_response(resp, 400)
      assert err["error"] == "invalid_params"
      assert err["detail"] =~ "merge"
    end

    test "rejects set op without value", %{conn: conn, token: token} do
      body = %{ops: [%{op: "set", path: "x"}]}
      resp = batch_write_post(conn, token, Jason.encode!(body))
      err = json_response(resp, 400)
      assert err["error"] == "invalid_params"
      assert err["detail"] =~ "value"
    end

    test "rejects present-but-invalid if_match (string) — does NOT silently drop it",
         %{conn: conn, token: token, store: store} do
      body = %{ops: [%{op: "set", path: "cas_str", value: 1, if_match: "5"}]}
      resp = batch_write_post(conn, token, Jason.encode!(body))

      err = json_response(resp, 400)
      assert err["error"] == "invalid_params"
      assert err["detail"] =~ "if_match"

      # The op did not commit — silent drop would have turned this
      # into an unconditional write.
      assert Sync.get_entry(store.id, "cas_str") == nil
    end

    test "rejects if_match: 0", %{conn: conn, token: token} do
      body = %{ops: [%{op: "delete", path: "x", if_match: 0}]}
      resp = batch_write_post(conn, token, Jason.encode!(body))
      err = json_response(resp, 400)
      assert err["error"] == "invalid_params"
      assert err["detail"] =~ "if_match"
    end

    test "rejects negative if_match", %{conn: conn, token: token} do
      body = %{ops: [%{op: "set", path: "x", value: 1, if_match: -1}]}
      resp = batch_write_post(conn, token, Jason.encode!(body))
      err = json_response(resp, 400)
      assert err["error"] == "invalid_params"
      assert err["detail"] =~ "if_match"
    end

    test "store op_count increments by the batch size, not by 1",
         %{conn: conn, token: token, store: store} do
      before = Dust.Repo.get!(Dust.Stores.Store, store.id).op_count

      body = %{
        ops: [
          %{op: "set", path: "opcount/a", value: 1},
          %{op: "set", path: "opcount/b", value: 2},
          %{op: "set", path: "opcount/c", value: 3}
        ]
      }

      resp = batch_write_post(conn, token, Jason.encode!(body))
      _ = json_response(resp, 200)

      after_seq = Dust.Repo.get!(Dust.Stores.Store, store.id).op_count
      assert after_seq - before == 3
    end

    test "normalizes slashed paths", %{conn: conn, token: token, store: store} do
      body = %{ops: [%{op: "set", path: "users/charlie/name", value: "Charlie"}]}
      resp = batch_write_post(conn, token, Jason.encode!(body))
      result = json_response(resp, 200)

      assert hd(result["ops"])["path"] == "users.charlie.name"
      assert %{value: "Charlie"} = Sync.get_entry(store.id, "users.charlie.name")
    end

    test "returns 403 without write permission", %{conn: conn, store: store, user: user} do
      {:ok, ro_token} =
        Stores.create_store_token(store, %{
          name: "ro-batch",
          read: true,
          write: false,
          created_by_id: user.id
        })

      body = %{ops: [%{op: "set", path: "x", value: 1}]}
      resp = batch_write_post(conn, ro_token, Jason.encode!(body))
      assert resp.status == 403
    end

    test "returns 401 without bearer", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch_write",
          Jason.encode!(%{ops: [%{op: "set", path: "x", value: 1}]})
        )

      assert resp.status == 401
    end
  end

  describe "HEAD /api/stores/:org/:store/entries/*path" do
    test "returns 200 + ETag for an existing leaf", %{conn: conn, token: token, store: store} do
      %{seq: seq} = Sync.get_entry(store.id, "users.alice.name")

      resp =
        conn
        |> api_conn(token)
        |> head("/api/stores/entriesorg/mystore/entries/users/alice/name")

      assert resp.status == 200
      assert resp.resp_body == ""
      assert get_resp_header(resp, "etag") == [~s("#{seq}")]
    end

    test "returns 200 for a subtree path (existence probe)", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> head("/api/stores/entriesorg/mystore/entries/users/alice")

      assert resp.status == 200
      assert resp.resp_body == ""
      # ETag carries the max seq across descendants
      [etag] = get_resp_header(resp, "etag")
      assert etag =~ ~r/^"\d+"$/
    end

    test "returns 404 with empty body for missing path", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> head("/api/stores/entriesorg/mystore/entries/no/such/path")

      assert resp.status == 404
      assert resp.resp_body == ""
    end

    test "returns 401 without Bearer token", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> head("/api/stores/entriesorg/mystore/entries/users/alice/name")

      assert resp.status == 401
    end

    test "returns 403 without read permission", %{conn: conn, store: store, user: user} do
      {:ok, no_read_token} =
        Stores.create_store_token(store, %{
          name: "no-read-tok",
          read: false,
          write: true,
          created_by_id: user.id
        })

      resp =
        conn
        |> api_conn(no_read_token)
        |> head("/api/stores/entriesorg/mystore/entries/users/alice/name")

      assert resp.status == 403
    end

    test "returns 400 for '.' in URL segment", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> head("/api/stores/entriesorg/mystore/entries/foo.bar/baz")

      assert resp.status == 400
    end
  end

  describe "DELETE /api/stores/:org/:store/entries/*path" do
    test "removes a leaf entry", %{conn: conn, token: token, store: store} do
      assert %{value: "Alice"} = Sync.get_entry(store.id, "users.alice.name")

      resp =
        conn
        |> api_conn(token)
        |> delete("/api/stores/entriesorg/mystore/entries/users/alice/name")

      body = json_response(resp, 200)
      assert is_integer(body["revision"])
      assert body["revision"] == body["store_seq"]
      assert Sync.get_entry(store.id, "users.alice.name") == nil
    end

    test "removes an entire subtree", %{conn: conn, token: token, store: store} do
      assert %{value: %{}} = Sync.get_entry(store.id, "users.alice")
      assert %{value: %{}} = Sync.get_entry(store.id, "users.bob")

      resp =
        conn
        |> api_conn(token)
        |> delete("/api/stores/entriesorg/mystore/entries/users/alice")

      _body = json_response(resp, 200)
      assert Sync.get_entry(store.id, "users.alice") == nil
      assert Sync.get_entry(store.id, "users.alice.email") == nil
      assert Sync.get_entry(store.id, "users.alice.name") == nil
      # Other subtrees untouched.
      assert %{value: "Bob"} = Sync.get_entry(store.id, "users.bob.name")
    end

    test "is idempotent — DELETE on missing key still returns 200", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> delete("/api/stores/entriesorg/mystore/entries/no/such/path")

      body = json_response(resp, 200)
      assert is_integer(body["revision"])
    end

    test "DELETE with matching If-Match succeeds", %{conn: conn, token: token, store: store} do
      %{seq: seq} = Sync.get_entry(store.id, "users.alice.name")

      resp =
        conn
        |> api_conn(token)
        |> put_req_header("if-match", Integer.to_string(seq))
        |> delete("/api/stores/entriesorg/mystore/entries/users/alice/name")

      _body = json_response(resp, 200)
      assert Sync.get_entry(store.id, "users.alice.name") == nil
    end

    test "DELETE with stale If-Match returns 412", %{conn: conn, token: token, store: store} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("if-match", "999999")
        |> delete("/api/stores/entriesorg/mystore/entries/users/alice/name")

      body = json_response(resp, 412)
      assert body["error"] == "conflict"
      # Entry is unchanged.
      assert %{value: "Alice"} = Sync.get_entry(store.id, "users.alice.name")
    end

    test "DELETE without write permission returns 403", %{conn: conn, store: store, user: user} do
      {:ok, ro_token} =
        Stores.create_store_token(store, %{
          name: "ro-tok",
          read: true,
          write: false,
          created_by_id: user.id
        })

      resp =
        conn
        |> api_conn(ro_token)
        |> delete("/api/stores/entriesorg/mystore/entries/users/alice/name")

      assert resp.status == 403
    end

    test "DELETE with '.' in URL segment returns 400", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> delete("/api/stores/entriesorg/mystore/entries/foo.bar/baz")

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] =~ "'.'"
    end

    test "DELETE without Bearer token returns 401", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> delete("/api/stores/entriesorg/mystore/entries/users/alice/name")

      assert resp.status == 401
    end
  end

  describe "path normalization (slash ↔ dot)" do
    test "GET /entries?pattern=users/alice/* matches as if it were users.alice.*",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users/alice/*")

      body = json_response(resp, 200)
      paths = Enum.map(body["items"], & &1["path"])
      assert "users.alice.email" in paths
      assert "users.alice.name" in paths
    end

    test "GET /entries?from=users/alice&to=users/bob normalises range bounds",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?from=users/alice&to=users/bob")

      body = json_response(resp, 200)
      paths = Enum.map(body["items"], & &1["path"])
      assert "users.alice.email" in paths
      assert "users.alice.name" in paths
      refute Enum.any?(paths, &String.starts_with?(&1, "users.bob"))
    end

    test "PUT /entries/foo.bar/baz returns 400 — '.' in URL segment is forbidden",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> put("/api/stores/entriesorg/mystore/entries/foo.bar/baz", "\"x\"")

      body = json_response(resp, 400)
      assert body["error"] == "invalid_params"
      assert body["detail"] =~ "'.'"
    end

    test "POST /entries/batch normalises slashed paths in the body",
         %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries/batch",
          Jason.encode!(%{paths: ["users/alice/email", "users.bob.name"]})
        )

      body = json_response(resp, 200)
      assert Map.has_key?(body["entries"], "users.alice.email")
      assert Map.has_key?(body["entries"], "users.bob.name")
    end
  end

  # ---------------------------------------------------------------------
  # Session auth + body-path routes (the UI's path through the API)
  # ---------------------------------------------------------------------

  describe "session auth — bearer fallback" do
    setup %{conn: conn, user: user} do
      session_token = Accounts.generate_user_session_token(user)
      logged_in = init_test_session(conn, %{user_token: session_token})
      %{logged_in: logged_in}
    end

    test "GET /entries works with session for a member of the org",
         %{logged_in: conn} do
      resp = get(conn, "/api/stores/entriesorg/mystore/entries?pattern=users.**&limit=10")
      body = json_response(resp, 200)
      assert length(body["items"]) == 3
    end

    test "GET /entries 401s when neither bearer nor session is present", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/stores/entriesorg/mystore/entries")

      assert json_response(resp, 401) == %{"error" => "unauthorized"}
    end

    test "session user without org membership 401s", %{conn: conn} do
      {:ok, outsider} = Accounts.create_user(%{email: "outsider@example.com"})
      token = Accounts.generate_user_session_token(outsider)
      conn = init_test_session(conn, %{user_token: token})

      resp = get(conn, "/api/stores/entriesorg/mystore/entries")
      assert json_response(resp, 401) == %{"error" => "unauthorized"}
    end
  end

  describe "POST /api/stores/:org/:store/entries (body path)" do
    setup %{conn: conn, user: user} do
      session_token = Accounts.generate_user_session_token(user)
      logged_in = init_test_session(conn, %{user_token: session_token})
      %{logged_in: logged_in}
    end

    test "session-authed POST with {path, value} upserts",
         %{logged_in: conn, store: store} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{path: "links.foo.title", value: "Foo"})
        )

      body = json_response(resp, 200)
      assert is_integer(body["revision"])
      assert is_integer(body["store_seq"])

      # And the write actually landed in the store.
      assert Sync.get_entry(store.id, "links.foo.title").value == "Foo"
    end

    test "bearer-authed POST with {path, value} also works", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{path: "links.bar.title", value: "Bar"})
        )

      body = json_response(resp, 200)
      assert is_integer(body["store_seq"])
    end

    test "missing path 400s", %{logged_in: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{value: "no-path"})
        )

      assert resp.status == 400
    end

    test "missing value 400s (use DELETE for removal)", %{logged_in: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{path: "links.foo"})
        )

      assert resp.status == 400
    end

    test "if_match in body forwards through to CAS",
         %{logged_in: conn, store: store} do
      # Seed and capture the revision.
      seed_entry(store, "cas.target", "v0")
      rev = Sync.get_entry(store.id, "cas.target").seq

      # Successful CAS.
      ok_resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{path: "cas.target", value: "v1", if_match: rev})
        )

      assert json_response(ok_resp, 200)

      # Failed CAS using stale rev.
      fail_resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{path: "cas.target", value: "v2", if_match: rev})
        )

      assert json_response(fail_resp, 412)["error"] == "conflict"
    end

    test "non-positive if_match 400s", %{logged_in: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{path: "x", value: "y", if_match: 0})
        )

      assert resp.status == 400
    end
  end

  describe "DELETE /api/stores/:org/:store/entries (body path)" do
    setup %{conn: conn, user: user} do
      session_token = Accounts.generate_user_session_token(user)
      logged_in = init_test_session(conn, %{user_token: session_token})
      %{logged_in: logged_in}
    end

    test "session-authed DELETE with {path} removes the entry",
         %{logged_in: conn, store: store} do
      seed_entry(store, "to.delete", "bye")
      assert Sync.get_entry(store.id, "to.delete")

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{path: "to.delete"})
        )

      assert json_response(resp, 200)
      assert Sync.get_entry(store.id, "to.delete") == nil
    end

    test "missing path 400s", %{logged_in: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(
          "/api/stores/entriesorg/mystore/entries",
          Jason.encode!(%{})
        )

      assert resp.status == 400
    end
  end

end
