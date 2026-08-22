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
          # ip: :: — Bandit otherwise binds IPv4-only, and Fly's private
          # network (6PN, what document_compliance_engine reaches this on
          # in prod) is IPv6-only. Dual-stack on Linux still accepts IPv4
          # (e.g. localhost in dev/test) unless IPV6_V6ONLY is set, which
          # this doesn't do.
          {Bandit, plug: SanctionsDb.Router, port: port, ip: {0, 0, 0, 0, 0, 0, 0, 0}}
        ]
    end
  end
end
