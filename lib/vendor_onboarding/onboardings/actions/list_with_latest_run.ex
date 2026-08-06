defmodule VendorOnboarding.Onboardings.Actions.ListWithLatestRun do
  @moduledoc """
  Dashboard read model: onboardings joined with each one's latest agent
  run. `run/1` batches the `AgentRuns` lookup (not N+1) for the full list;
  `reload/1` does the single-row equivalent for a PubSub-triggered row
  refresh. Each context is queried separately and merged here in
  Onboardings (the context that owns the list) — never via a query that
  reaches into AgentRuns's schema directly.
  """

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.Onboardings.Repository

  @spec run(keyword()) :: [map()]
  def run(opts \\ []) do
    onboardings = Repository.list(opts)
    ids = Enum.map(onboardings, & &1.id)
    latest_runs = AgentRuns.latest_by_onboarding_ids(ids)

    Enum.map(onboardings, &build_row(&1, Map.get(latest_runs, &1.id)))
  end

  @spec reload(pos_integer()) :: {:ok, map()} | {:error, :not_found}
  def reload(id) do
    with {:ok, onboarding} <- Repository.get(id) do
      agent_run =
        case AgentRuns.get_latest_for_onboarding(id) do
          {:ok, run} -> run
          {:error, :not_found} -> nil
        end

      {:ok, build_row(onboarding, agent_run)}
    end
  end

  defp build_row(onboarding, agent_run) do
    %{
      id: onboarding.id,
      status: onboarding.status,
      company_name: agent_run && agent_run.company_name,
      updated_at: onboarding.updated_at
    }
  end
end
