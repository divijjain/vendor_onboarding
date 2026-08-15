defmodule SanctionsDb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: SanctionsDb.Supervisor)
  end

  # nil port in test: the watchlist rule is exercised as a pure function.
  defp children do
    case Application.get_env(:sanctions_db, :port, 8011) do
      nil ->
        []

      port ->
        [
          Hermes.Server.Registry,
          {SanctionsDb.Server, transport: :streamable_http},
          {Bandit, plug: SanctionsDb.Router, port: port}
        ]
    end
  end
end
