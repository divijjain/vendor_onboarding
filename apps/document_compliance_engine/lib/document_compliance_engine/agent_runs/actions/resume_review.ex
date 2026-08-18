defmodule DocumentComplianceEngine.AgentRuns.Actions.ResumeReview do
  @moduledoc """
  Human approval/rejection from the LiveView review screen -> records an
  immutable audit record of the decision (reviewer, rationale, and a
  snapshot of the evidence the reviewer had in front of them), then
  enqueues `ResumeAgentRunWorker`. The audit record is written before the
  resume is enqueued: a decision without a recorded reviewer/rationale
  never reaches the pipeline. Doesn't write agent_run status locally —
  `HandleAgentCallback` is still the single writer of final status,
  keeping one source of truth.
  """

  alias DocumentComplianceEngine.AgentRuns.Repository

  alias DocumentComplianceEngine.AgentRuns.ReviewDecisions.Repository,
    as: ReviewDecisionsRepository

  alias DocumentComplianceEngine.AgentRuns.Workers.ResumeAgentRunWorker
  alias DocumentComplianceEngine.DocumentJobs

  @spec call(pos_integer(), :approved | :rejected, String.t(), String.t()) ::
          {:ok, DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob.t()} | {:error, term()}
  def call(document_job_id, decision, reviewer, rationale)
      when decision in [:approved, :rejected] do
    with {:ok, document_job} <- DocumentJobs.get_document_job(document_job_id),
         :ok <- ensure_needs_review(document_job),
         {:ok, agent_run} <- Repository.get_latest_for_document_job(document_job_id),
         {:ok, _review_decision} <-
           ReviewDecisionsRepository.insert(%{
             document_job_id: document_job.id,
             thread_id: agent_run.thread_id,
             decision: decision,
             reviewer: reviewer,
             rationale: rationale,
             evidence: agent_run.explanation
           }),
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
