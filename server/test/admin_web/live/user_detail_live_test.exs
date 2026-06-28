defmodule AdminWeb.UserDetailLiveTest do
  use AdminWeb.ConnCase, async: true

  import Dust.AccountsFixtures

  test "shows the user and the organizations they belong to", %{conn: conn} do
    user = user_fixture(%{email: "profile@example.com"})
    org = organization_fixture(%{slug: "their-org"}, user)

    {:ok, view, html} = live(conn, ~p"/users/#{user.id}")

    assert html =~ "profile@example.com"
    assert html =~ "their-org"
    assert html =~ "owner"
    assert view |> element("a", "their-org") |> render() =~ ~p"/orgs/#{org.id}"
  end
end
