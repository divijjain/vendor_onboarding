defmodule DocumentComplianceEngineWeb.Router do
  use DocumentComplianceEngineWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DocumentComplianceEngineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook do
    plug DocumentComplianceEngineWeb.Plugs.VerifyWebhookSignature
  end

  scope "/", DocumentComplianceEngineWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/document_jobs", DashboardLive
    live "/document_jobs/:id", ReviewLive
  end

  scope "/webhooks", DocumentComplianceEngineWeb do
    pipe_through [:api, :webhook]

    post "/document_compliance_engine", WebhookController, :create
  end

  scope "/mcp" do
    pipe_through :api

    forward "/", Hermes.Server.Transport.StreamableHTTP.Plug,
      server: DocumentComplianceEngine.Mcp.Server
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:document_compliance_engine, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DocumentComplianceEngineWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
