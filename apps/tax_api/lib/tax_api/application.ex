defmodule TaxApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: TaxApi.Supervisor)
  end

  # nil port in test: the tool rule is exercised as a pure function.
  defp children do
    case Application.get_env(:tax_api, :port, 8010) do
      nil ->
        []

      port ->
        [
          Hermes.Server.Registry,
          {TaxApi.Server, transport: :streamable_http},
          {Bandit, plug: TaxApi.Router, port: port}
        ]
    end
  end
end
