defmodule DocumentComplianceEngineWeb.PageController do
  @moduledoc """
  This is an internal back-office tool, not a marketing site — a signed-in
  visitor is redirected straight to the dashboard. A signed-out visitor
  can't be redirected to `/document_jobs` (it's behind the
  `:require_authenticated_user` `live_session` and would just redirect
  back here, an infinite loop) — they get a minimal sign-in page instead.
  `current_user` is already assigned by the `:fetch_current_user` plug on
  the `:browser` pipeline, which (unlike the LiveView `on_mount` hook) does
  not require a signed-in user.
  """

  use DocumentComplianceEngineWeb, :controller

  def home(%{assigns: %{current_user: nil}} = conn, _params) do
    render(conn, :home)
  end

  def home(conn, _params) do
    redirect(conn, to: ~p"/document_jobs")
  end
end
