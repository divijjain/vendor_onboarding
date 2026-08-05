defmodule VendorOnboardingWeb.PageController do
  use VendorOnboardingWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
