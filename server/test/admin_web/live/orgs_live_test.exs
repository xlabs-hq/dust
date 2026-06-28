defmodule AdminWeb.OrgsLiveTest do
  use AdminWeb.ConnCase, async: true

  import Dust.AccountsFixtures

  test "lists organizations with their plan", %{conn: conn} do
    organization_fixture(%{slug: "visible-org"})

    {:ok, _view, html} = live(conn, ~p"/orgs")

    assert html =~ "Organizations"
    assert html =~ "visible-org"
    assert html =~ "free"
  end

  test "links each organization to its detail page", %{conn: conn} do
    org = organization_fixture(%{slug: "linked-org"})

    {:ok, view, _html} = live(conn, ~p"/orgs")

    assert view |> element("a", "linked-org") |> render() =~ ~p"/orgs/#{org.id}"
  end
end
