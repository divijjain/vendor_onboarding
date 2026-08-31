defmodule DocumentComplianceEngineWeb.Router do
  use DocumentComplianceEngineWeb, :router

  import DocumentComplianceEngineWeb.UserAuth,
    only: [fetch_current_user: 2, require_authenticated_user: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DocumentComplianceEngineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook do
    plug DocumentComplianceEngineWeb.Plugs.VerifyWebhookSignature
  end

  # Controller-side equivalent of the `live_session`'s `:ensure_authenticated`
  # on_mount hook — on_mount doesn't run for plain controller routes. Named
  # differently from the imported `require_authenticated_user/2` plug it
  # wraps — Phoenix's `pipeline/2` can't share a name with an import.
  pipeline :require_auth do
    plug :require_authenticated_user
  end

  scope "/", DocumentComplianceEngineWeb do
    pipe_through :browser

    get "/", PageController, :home

    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :delete

    live_session :require_authenticated_user,
      on_mount: [
        {DocumentComplianceEngineWeb.UserAuth, :ensure_authenticated},
        {DocumentComplianceEngineWeb.UserAuth, :ensure_organization}
      ] do
      live "/document_jobs", DashboardLive
      live "/document_jobs/:id", ReviewLive
      live "/audits", AuditLive
      live "/organizations", OrganizationLive
    end

    live_session :require_no_organization,
      on_mount: [
        {DocumentComplianceEngineWeb.UserAuth, :ensure_authenticated},
        {DocumentComplianceEngineWeb.UserAuth, :ensure_no_organization}
      ] do
      live "/organizations/new", CreateOrganizationLive
    end
  end

  scope "/", DocumentComplianceEngineWeb do
    pipe_through [:browser, :require_auth]

    # Serves original document bytes for ReviewLive's viewer. Organization
    # scoping is enforced in the controller's query, not here.
    get "/document_jobs/:id/documents/:role", DocumentController, :show
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
