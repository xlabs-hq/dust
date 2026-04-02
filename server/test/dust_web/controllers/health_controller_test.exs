defmodule DustWeb.HealthControllerTest do
  use DustWeb.ConnCase, async: true

  test "GET /healthz returns 200", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert json_response(conn, 200)["status"] == "ok"
  end

  test "GET /readyz returns 200 when healthy", %{conn: conn} do
    conn = get(conn, "/readyz")
    body = json_response(conn, 200)
    assert body["status"] == "ok"
    assert body["checks"]["database"] == "ok"
    assert body["checks"]["pubsub"] == "ok"
  end
end
