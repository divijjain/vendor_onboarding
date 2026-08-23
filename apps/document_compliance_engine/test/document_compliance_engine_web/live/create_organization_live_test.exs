defmodule DocumentComplianceEngineWeb.CreateOrganizationLiveTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.Accounts

  test "redirects to / when not signed in" do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/organizations/new")
  end

  test "redirects to /document_jobs when the user already has an organization", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: "/document_jobs"}}} = live(conn, ~p"/organizations/new")
  end

  test "creates an organization and redirects to /document_jobs", %{conn: conn} do
    user = user_fixture(%{organization_id: nil})
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/organizations/new")

    # redirect/2 (not push_navigate/2) always forces a real reconnect, so
    # follow_redirect/2 follows it as a plain HTTP request and hands back
    # the resulting conn, not a re-mounted {:ok, view, html}.
    {:ok, new_conn} =
      view
      |> form("#create-organization-form", %{name: "Acme Corp"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/document_jobs")

    assert html_response(new_conn, 200) =~ "Organization created."

    assert {:ok, updated_user} = Accounts.get_user(user.id)
    assert updated_user.organization_id != nil
  end
end
