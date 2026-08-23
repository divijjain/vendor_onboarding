defmodule DocumentComplianceEngineWeb.UserAuth do
  @moduledoc """
  Session-based login for Google-only auth. Deliberately simpler than
  `mix phx.gen.auth`'s usual shape: no `users_tokens` table, since there's
  no password reset / "sign out everywhere" requirement here — the signed
  session cookie holding a bare `user_id` is the only credential.
  """

  use DocumentComplianceEngineWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias DocumentComplianceEngine.Accounts

  @doc "Renews the session (fixation hygiene) and stores the signed-in user's id."
  def log_in_user(conn, user) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, user.id)
  end

  @doc "Clears the session entirely."
  def log_out_user(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc "Plug: assigns :current_user from the session, or nil, for controller-rendered pages."
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, load_user(get_session(conn, :user_id)))
  end

  @doc "Plug: redirects to the login page unless a user is already assigned."
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "You must sign in to access this page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc """
  LiveView on_mount hooks:
  - `:ensure_authenticated` — assigns `:current_user` or halts with a
    redirect to the login page.
  - `:ensure_organization` — requires `current_user` to already belong to
    an organization (must run after `:ensure_authenticated` in the same
    `live_session`'s `on_mount:` list) — halts with a redirect to the
    create-organization page otherwise. A signed-in user with no
    organization can't usefully reach `/document_jobs`/`/audits`/etc.
  - `:ensure_no_organization` — the inverse, for the create-organization
    page itself, so a user who already belongs to one can't create a
    second (this app is one-organization-per-user).
  """
  def on_mount(:ensure_authenticated, _params, session, socket) do
    case load_user(session["user_id"]) do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}

      user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    end
  end

  def on_mount(:ensure_organization, _params, _session, socket) do
    if socket.assigns.current_user.organization_id do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/organizations/new")}
    end
  end

  def on_mount(:ensure_no_organization, _params, _session, socket) do
    if socket.assigns.current_user.organization_id do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/document_jobs")}
    else
      {:cont, socket}
    end
  end

  defp load_user(nil), do: nil

  defp load_user(user_id) do
    case Accounts.get_user(user_id) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end
end
