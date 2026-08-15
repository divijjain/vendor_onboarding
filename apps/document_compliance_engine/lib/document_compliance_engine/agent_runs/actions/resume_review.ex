defmodule DocumentComplianceEngine.AgentRuns.Actions.ResumeReview do
  @moduledoc """
  Human approval/rejection from the LiveView review screen -> enqueues
  `ResumeAgentRunWorker`. Doesn't write status locally — `HandleAgentCallback`
  is still the single writer of final status, keeping one source of truth.
  """

  alias DocumentComplianceEngine.AgentRuns.Repository
  alias DocumentComplianceEngine.AgentRuns.Workers.ResumeAgentRunWorker
  alias DocumentComplianceEngine.DocumentJobs

  @spec call(pos_integer(), :approved | :rejected) ::
          {:ok, DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob.t()} | {:error, term()}
  def call(document_job_id, decision) when decision in [:approved, :rejected] do
    with {:ok, document_job} <- DocumentJobs.get_document_job(document_job_id),
         :ok <- ensure_needs_review(document_job),
         {:ok, agent_run} <- Repository.get_latest_for_document_job(document_job_id),
         {:ok, _job} <-
           ResumeAgentRunWorker.enqueue(
             document_job.id,
             agent_run.thread_id,
             Atom.to_string(decision)
           ) do
      {:ok, document_job}
    end
  end

  defp ensure_needs_review(%{status: :needs_review}), do: :ok
  defp ensure_needs_review(_document_job), do: {:error, :not_awaiting_review}
end
