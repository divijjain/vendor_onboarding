defmodule DocumentComplianceEngine.PromEx do
  @moduledoc """
  Exposes Prometheus metrics for BEAM/Phoenix/Ecto/Oban plus the agent
  pipeline's own domain metrics (see `PromEx.Plugins.Agent`), served over
  its own standalone HTTP listener rather than folded into the main
  Phoenix endpoint.

  That's a deliberate departure from how `/mcp` is mounted (see
  `Mcp.Server`'s moduledoc, and CLAUDE.md): `/mcp` is in-process control
  flow with no separate-port reason to exist, but a Prometheus scrape
  target is conventionally put on its own port precisely so it can be
  firewalled off from public traffic — the same shape a Kubernetes
  `NetworkPolicy` restricting a `/metrics` port to the in-cluster
  Prometheus pod would give you. `auth_strategy: :none` below is safe on
  that basis: `fly.toml` has no `[[services]]` block exposing this port,
  so in prod it's only reachable over Fly's private network, not the
  public internet — unauthenticated is fine because it's already
  network-isolated, not because the data is unimportant.

  No Grafana dashboards are wired up (`grafana: :disabled`) — this project
  has no Grafana instance to push them to; the plugins below still ship
  ready-made dashboard JSON a real one could import directly.
  """

  use PromEx, otp_app: :document_compliance_engine

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      {Plugins.Application, otp_app: :document_compliance_engine},
      Plugins.Beam,
      {Plugins.Phoenix,
       router: DocumentComplianceEngineWeb.Router, endpoint: DocumentComplianceEngineWeb.Endpoint},
      {Plugins.Ecto, repos: [DocumentComplianceEngine.Repo]},
      Plugins.Oban,
      DocumentComplianceEngine.PromEx.Plugins.Agent
    ]
  end

  @impl true
  def dashboard_assigns do
    [datasource_id: "prometheus", default_selected_interval: "30s"]
  end

  @impl true
  def dashboards do
    []
  end
end
