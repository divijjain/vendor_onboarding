defmodule VendorOnboarding.AgentRuns.Workers.TriggerAgentRunWorker do
  # Capped well below Oban's default of 20: a retry replays the *whole*
  # pipeline (re-extraction included) and, on a halt, collides with the
  # checkpoint's unique `thread_id` constraint — see CLAUDE.md's
  # "Agent-brain gotchas". Low attempts bound how often a transient failure
  # burns a full re-extraction rather than eliminating the risk outright.
  use Oban.Worker, queue: :agent_runs, max_attempts: 3

  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(document_job_id) do
    %{document_job_id: document_job_id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_job_id" => document_job_id}}) do
    case VendorOnboarding.AgentRuns.trigger_agent_run(document_job_id) do
      {:ok, _agent_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
