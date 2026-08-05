defmodule VendorOnboarding.Workers.TriggerAgentRunWorker do
  use Oban.Worker, queue: :agent_runs, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"onboarding_id" => onboarding_id}}) do
    case VendorOnboarding.trigger_agent_run(onboarding_id) do
      {:ok, _onboarding} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
