defmodule DocumentComplianceEngineWeb.OrganizationLiveTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  test "redirects to / when not signed in" do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/organizations")
  end

  test "redirects to /organizations/new when the user has no organization yet", %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{organization_id: nil}))

    assert {:error, {:redirect, %{to: "/organizations/new"}}} = live(conn, ~p"/organizations")
  end

  test "shows the organization's name and members", %{conn: conn} do
    owner = user_fixture()
    teammate = user_fixture(%{organization_id: owner.organization_id})
    conn = log_in_user(conn, owner)

    {:ok, _view, html} = live(conn, ~p"/organizations")

    assert html =~ owner.email
    assert html =~ teammate.email
  end

  test "sends an invite and shows it as pending", %{conn: conn} do
    owner = user_fixture()
    conn = log_in_user(conn, owner)

    {:ok, view, _html} = live(conn, ~p"/organizations")

    html =
      view
      |> form("#invite-member-form", %{email: "teammate@example.com"})
      |> render_submit()

    assert html =~ "Invited teammate@example.com"
    assert html =~ "teammate@example.com"
  end
end
