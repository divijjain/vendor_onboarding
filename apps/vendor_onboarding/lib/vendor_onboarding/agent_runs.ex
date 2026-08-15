defmodule VendorOnboarding.AgentRuns do
  @moduledoc """
  Public API for the agent-orchestration domain. `defdelegate` only — no
  logic here. Owns the `agent_runs` table: the extracted/validated output
  of each run against a given document_job, including history across
  re-runs. See `VendorOnboarding.DocumentJobs` for the ingestion record.
  """

  alias VendorOnboarding.AgentRuns.Actions.{HandleAgentCallback, ResumeReview, TriggerAgentRun}
  alias VendorOnboarding.AgentRuns.Repository
  alias VendorOnboarding.AgentRuns.Workers.TriggerAgentRunWorker

  defdelegate get_latest_for_document_job(document_job_id), to: Repository
  defdelegate latest_by_document_job_ids(ids), to: Repository
  defdelegate enqueue_trigger(document_job_id), to: TriggerAgentRunWorker, as: :enqueue
  defdelegate trigger_agent_run(document_job_id), to: TriggerAgentRun, as: :call
  defdelegate handle_agent_callback(params), to: HandleAgentCallback, as: :call
  defdelegate resume_review(document_job_id, decision), to: ResumeReview, as: :call
  defdelegate count_active(), to: Repository
end
