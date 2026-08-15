defmodule DocumentComplianceEngineWeb.PageController do
  @moduledoc """
  This is an internal back-office tool, not a marketing site — the root
  path redirects straight to the dashboard rather than rendering a
  separate landing page.
  """

  use DocumentComplianceEngineWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/document_jobs")
  end
end
