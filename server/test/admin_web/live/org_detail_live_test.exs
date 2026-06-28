defmodule AdminWeb.OrgDetailLiveTest do
  use AdminWeb.ConnCase, async: true

  import Dust.AccountsFixtures

  alias Dust.Accounts
  alias Dust.Repo
  alias Dust.Stores.Store

  test "shows org info, current plan and limits", %{conn: conn} do
    org = organization_fixture(%{slug: "detail-org"})

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.id}")

    assert html =~ "detail-org"
    assert html =~ "Plan"
    # free plan limits
    assert html =~ "1,000"
    assert html =~ "7 days"
  end

  test "lists members and stores", %{conn: conn} do
    user = user_fixture(%{email: "member@example.com"})
    org = organization_fixture(%{slug: "with-members"}, user)
    # Insert a bare store row (no per-store SQLite DB) so the test stays async.
    Repo.insert!(%Store{organization_id: org.id, name: "the-store", status: :active})

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.id}")

    assert render(view) =~ "member@example.com"
    assert view |> element("a", "the-store") |> has_element?()
  end

  describe "changing the plan" do
    setup %{conn: conn} do
      org = organization_fixture(%{slug: "upgrade-me"})
      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.id}")
      %{org: org, view: view}
    end

    test "selecting a plan reveals an inline confirmation, not an immediate change",
         %{view: view, org: org} do
      refute has_element?(view, "#plan-confirm")

      view
      |> element("button[phx-value-plan='pro']")
      |> render_click()

      assert has_element?(view, "#plan-confirm")
      # Plan is not changed until confirmed
      assert Accounts.get_organization!(org.id).plan == "free"
    end

    test "confirming applies the change and shows a notice", %{view: view, org: org} do
      view |> element("button[phx-value-plan='pro']") |> render_click()
      html = view |> element("button", "Confirm change to pro") |> render_click()

      assert html =~ "Plan changed to pro."
      assert Accounts.get_organization!(org.id).plan == "pro"
      # confirmation panel is dismissed
      refute has_element?(view, "#plan-confirm")
    end

    test "cancelling dismisses the confirmation without changing the plan",
         %{view: view, org: org} do
      view |> element("button[phx-value-plan='team']") |> render_click()
      assert has_element?(view, "#plan-confirm")

      view |> element("button", "Cancel") |> render_click()

      refute has_element?(view, "#plan-confirm")
      assert Accounts.get_organization!(org.id).plan == "free"
    end
  end
end
