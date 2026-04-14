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

    test "select=prefixes with invalid pattern returns 400", %{conn: conn, token: token} do
      resp =
        conn
        |> api_conn(token)
        |> get("/api/stores/entriesorg/mystore/entries?pattern=users.*&select=prefixes")

      assert %{"error" => "invalid_pattern_for_prefixes"} = json_response(resp, 400)
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
        |> get("/api/stores/entriesorg/mystore/entries/users.alice.name")

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
        |> get("/api/stores/entriesorg/mystore/entries/no.such.path")

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
        |> get("/api/stores/entriesorg/mystore/entries/users.alice.name")

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
          "/api/stores/entriesorg/mystore/entries/users.alice.name",
          ~s("Alice Updated")
        )

      body = json_response(resp, 200)
      assert is_integer(body["revision"])
      assert body["revision"] == body["store_seq"]

      # Verify the value was actually written.
      assert %{value: "Alice Updated"} = Sync.get_entry(store.id, "users.alice.name")
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
        |> put("/api/stores/entriesorg/mystore/entries/cas.counter", "2")

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
        |> put("/api/stores/entriesorg/mystore/entries/cas.counter", "2")

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
          "/api/stores/entriesorg/mystore/entries/users.alice",
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
        |> put("/api/stores/entriesorg/mystore/entries/cas.counter", "1")

      assert resp.status == 401
    end
  end
end
