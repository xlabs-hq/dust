defmodule AdminWeb.UsersLiveTest do
  use AdminWeb.ConnCase, async: true

  import Dust.AccountsFixtures

  test "lists users and links to their detail page", %{conn: conn} do
    user = user_fixture(%{email: "listed@example.com"})

    {:ok, view, html} = live(conn, ~p"/users")

    assert html =~ "Users"
    assert html =~ "listed@example.com"
    assert view |> element("a", "listed@example.com") |> render() =~ ~p"/users/#{user.id}"
  end
end
