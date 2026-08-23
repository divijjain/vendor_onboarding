defmodule DocumentComplianceEngineWeb.PageControllerTest do
  use DocumentComplianceEngineWeb.ConnCase

  import DocumentComplianceEngine.AccountsFixtures

  test "GET / shows a sign-in page when logged out", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Sign in with Google"
  end

  test "GET / redirects to the dashboard when already signed in", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/document_jobs"
  end
end
