defmodule DocumentComplianceEngine.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DocumentComplianceEngineWeb.Telemetry,
      DocumentComplianceEngine.Repo,
      DocumentComplianceEngine.Vault,
      {DNSCluster,
       query: Application.get_env(:document_compliance_engine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DocumentComplianceEngine.PubSub},
      {Oban, Application.fetch_env!(:document_compliance_engine, Oban)},
      Hermes.Server.Registry,
      {DocumentComplianceEngine.Mcp.Server, transport: :streamable_http},
      # After Repo/Oban, not before: its polling metrics (active_agent_runs,
      # Oban queue depth) query both, and `manual_metrics_start_delay:
      # :no_delay` (config.exs) makes the first poll fire immediately on
      # start — ahead of Repo even existing yet, if this were earlier in
      # a `:one_for_one` supervisor's start order. Caught by `mix test`
      # actually booting the app, not assumed safe from reading the docs.
      DocumentComplianceEngine.PromEx,
      # Start to serve requests, typically the last entry
      DocumentComplianceEngineWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DocumentComplianceEngine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DocumentComplianceEngineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
