defmodule DocumentComplianceEngineWeb.AuthControllerTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.Organizations
  alias DocumentComplianceEngineWeb.AuthController

  # `plug Ueberauth` in AuthController only runs as part of the router's
  # plug pipeline (Controller.call/2) — invoking the action function
  # directly, as below, bypasses it entirely, which is exactly what's
  # wanted: simulate what a completed OAuth2 handshake leaves in
  # conn.assigns, without driving a real Google redirect/callback.
  defp conn_with_session(conn) do
    Phoenix.ConnTest.init_test_session(conn, %{})
  end

  test "callback/2 signs in and redirects on a successful Google auth", %{conn: conn} do
    auth = %Ueberauth.Auth{
      uid: "google-sub-abc",
      provider: :google,
      info: %Ueberauth.Auth.Info{
        email: "new-login@example.com",
        name: "New Login",
        image: "https://example.com/a.png"
      }
    }

    conn =
      conn
      |> conn_with_session()
      |> Plug.Conn.assign(:ueberauth_auth, auth)
      |> AuthController.callback(%{})

    assert redirected_to(conn) == ~p"/document_jobs"
    assert %{id: user_id} = Accounts.Repository.get_by_google_sub("google-sub-abc")
    assert Plug.Conn.get_session(conn, :user_id) == user_id
  end

  test "callback/2 links a pre-provisioned (webhook owner_email) account instead of duplicating it",
       %{conn: conn} do
    {:ok, pre_provisioned} = Accounts.get_or_create_user_by_email("pre-provisioned@example.com")

    auth = %Ueberauth.Auth{
      uid: "google-sub-link",
      provider: :google,
      info: %Ueberauth.Auth.Info{email: "pre-provisioned@example.com", name: "Linked", image: nil}
    }

    conn =
      conn
      |> conn_with_session()
      |> Plug.Conn.assign(:ueberauth_auth, auth)
      |> AuthController.callback(%{})

    assert Plug.Conn.get_session(conn, :user_id) == pre_provisioned.id
  end

  test "callback/2 joins the invited organization when a pending invite matches the email",
       %{conn: conn} do
    inviter = user_fixture()
    {:ok, _invitation} = Organizations.invite_member(inviter, "invited@example.com")

    auth = %Ueberauth.Auth{
      uid: "google-sub-invited",
      provider: :google,
      info: %Ueberauth.Auth.Info{email: "invited@example.com", name: "Invitee", image: nil}
    }

    conn
    |> conn_with_session()
    |> Plug.Conn.assign(:ueberauth_auth, auth)
    |> AuthController.callback(%{})

    assert %{organization_id: organization_id} =
             Accounts.Repository.get_by_google_sub("google-sub-invited")

    assert organization_id == inviter.organization_id
  end

  test "callback/2 for a brand-new email with no pending invite leaves organization_id nil",
       %{conn: conn} do
    auth = %Ueberauth.Auth{
      uid: "google-sub-no-invite",
      provider: :google,
      info: %Ueberauth.Auth.Info{email: "no-invite@example.com", name: "Nobody", image: nil}
    }

    conn
    |> conn_with_session()
    |> Plug.Conn.assign(:ueberauth_auth, auth)
    |> AuthController.callback(%{})

    assert %{organization_id: nil} = Accounts.Repository.get_by_google_sub("google-sub-no-invite")
  end

  test "callback/2 flashes an error and redirects home on ueberauth_failure", %{conn: conn} do
    failure = %Ueberauth.Failure{
      errors: [%Ueberauth.Failure.Error{message_key: "invalid", message: "invalid credentials"}]
    }

    conn =
      conn
      |> conn_with_session()
      |> Phoenix.Controller.fetch_flash([])
      |> Plug.Conn.assign(:ueberauth_failure, failure)
      |> AuthController.callback(%{})

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not authenticate"
  end

  test "delete/2 clears the session and redirects home", %{conn: conn} do
    {:ok, user} = Accounts.get_or_create_user_by_email("logout@example.com")

    conn =
      conn
      |> conn_with_session()
      |> Plug.Conn.put_session(:user_id, user.id)
      |> AuthController.delete(%{})

    assert redirected_to(conn) == ~p"/"
    assert Plug.Conn.get_session(conn, :user_id) == nil
  end
end
