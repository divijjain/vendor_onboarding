defmodule VendorOnboarding.Workers.TriggerAgentRunWorker do
  @moduledoc """
  Stub for CONTEXT.md build-order step 2 — proves the async enqueue path
  works end to end. Step 3 replaces this body with the real dispatch to
  the Python service via `VendorOnboarding.trigger_agent_run/1`.
  """

  use Oban.Worker, queue: :agent_runs, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"onboarding_id" => _onboarding_id}}) do
    :ok
  end
end
