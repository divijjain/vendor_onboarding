defmodule VendorOnboarding.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VendorOnboardingWeb.Telemetry,
      VendorOnboarding.Repo,
      VendorOnboarding.Vault,
      {DNSCluster, query: Application.get_env(:vendor_onboarding, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: VendorOnboarding.PubSub},
      {Oban, Application.fetch_env!(:vendor_onboarding, Oban)},
      # Start to serve requests, typically the last entry
      VendorOnboardingWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: VendorOnboarding.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VendorOnboardingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
