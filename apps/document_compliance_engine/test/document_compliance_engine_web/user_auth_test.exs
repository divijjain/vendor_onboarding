defmodule DocumentComplianceEngineWeb.UserAuthTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngineWeb.UserAuth

  describe "log_in_user/2 and log_out_user/1" do
    test "log_in_user stores user_id in a renewed session", %{conn: conn} do
      {:ok, user} = Accounts.get_or_create_user_by_email("session@example.com")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> UserAuth.log_in_user(user)

      assert Plug.Conn.get_session(conn, :user_id) == user.id
    end

    test "log_out_user clears the session", %{conn: conn} do
      {:ok, user} = Accounts.get_or_create_user_by_email("session2@example.com")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)
        |> UserAuth.log_out_user()

      assert Plug.Conn.get_session(conn, :user_id) == nil
    end
  end

  describe "fetch_current_user/2" do
    test "assigns the user found in the session", %{conn: conn} do
      {:ok, user} = Accounts.get_or_create_user_by_email("fetch@example.com")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
    end

    test "assigns nil when there's no session", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end
  end

  describe "require_authenticated_user/2" do
    test "passes through unchanged when a user is assigned", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.assign(:current_user, %{id: 1})
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end

    test "redirects to / and halts when no user is assigned", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash([])
        |> Plug.Conn.assign(:current_user, nil)
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "on_mount ordering, driven through the real router" do
    test "an unauthenticated request to a gated route redirects to /, not /organizations/new" do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/document_jobs")
    end

    test "an authenticated user with no organization redirects to /organizations/new", %{
      conn: conn
    } do
      conn = log_in_user(conn, user_fixture(%{organization_id: nil}))

      assert {:error, {:redirect, %{to: "/organizations/new"}}} =
               live(conn, ~p"/document_jobs")
    end

    test "an authenticated user with an organization reaches the gated route", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:ok, _view, _html} = live(conn, ~p"/document_jobs")
    end
  end
end
