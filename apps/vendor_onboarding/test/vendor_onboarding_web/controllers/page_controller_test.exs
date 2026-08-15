defmodule VendorOnboardingWeb.PageControllerTest do
  use VendorOnboardingWeb.ConnCase

  test "GET / redirects to the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/document_jobs"
  end
end
