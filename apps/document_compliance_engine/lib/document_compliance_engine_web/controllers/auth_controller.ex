defmodule DocumentComplianceEngineWeb.AuthController do
  use DocumentComplianceEngineWeb, :controller

  plug Ueberauth

  require Logger

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.Organizations
  alias DocumentComplianceEngineWeb.UserAuth

  @doc "Ueberauth's plug intercepts this action and redirects to Google — nothing to do here."
  def request(conn, _params), do: conn

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    attrs = %{
      email: auth.info.email,
      google_sub: auth.uid,
      name: auth.info.name,
      avatar_url: auth.info.image
    }

    case Accounts.find_or_create_user_from_google(attrs) do
      {:ok, user} ->
        # A user with no organization yet might have a pending invite
        # matching their email — accept it now, as a side effect of this
        # real, authenticated login (never from webhook/MCP ingestion,
        # see Organizations.Actions.AcceptPendingInvitation's moduledoc).
        # An org-join hiccup shouldn't block sign-in, so its result is
        # only logged, never surfaced as a login failure.
        case Organizations.accept_pending_invitation(user) do
          {:ok, _outcome} -> :ok
          {:error, reason} -> Logger.error("accept_pending_invitation failed: #{inspect(reason)}")
        end

        conn
        |> UserAuth.log_in_user(user)
        |> redirect(to: ~p"/document_jobs")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not sign you in — please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "Could not authenticate with Google.")
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> redirect(to: ~p"/")
  end
end
