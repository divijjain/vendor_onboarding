defmodule VendorOnboarding.AgentRuns.Workers.TriggerAgentRunWorker do
  use Oban.Worker, queue: :agent_runs, max_attempts: 5

  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(onboarding_id) do
    %{onboarding_id: onboarding_id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"onboarding_id" => onboarding_id}}) do
    case VendorOnboarding.AgentRuns.trigger_agent_run(onboarding_id) do
      {:ok, _agent_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
