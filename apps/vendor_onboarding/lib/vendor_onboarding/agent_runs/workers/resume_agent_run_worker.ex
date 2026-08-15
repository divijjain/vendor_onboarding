defmodule VendorOnboarding.AgentRuns.Workers.ResumeAgentRunWorker do
  @moduledoc """
  Runs the resumed half of the agent pipeline off the Oban queue — mirrors
  `TriggerAgentRunWorker`. Enqueued (rather than called inline) so the
  LiveView process handling the human's approve/reject click is never
  blocked on the agent pipeline, same principle the trigger path was
  already built on.
  """

  # See TriggerAgentRunWorker: capped well below Oban's default of 20 for
  # the same checkpoint-collision reason.
  use Oban.Worker, queue: :agent_runs, max_attempts: 3

  alias VendorOnboarding.Agent

  @spec enqueue(pos_integer(), String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(document_job_id, thread_id, decision) do
    %{document_job_id: document_job_id, thread_id: thread_id, decision: decision}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "document_job_id" => document_job_id,
          "thread_id" => thread_id,
          "decision" => decision
        }
      }) do
    Agent.Run.resume(document_job_id, thread_id, decision)
  end
end
