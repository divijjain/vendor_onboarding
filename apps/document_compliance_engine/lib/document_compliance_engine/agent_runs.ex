defmodule DocumentComplianceEngine.AgentRuns do
  @moduledoc """
  Public API for the agent-orchestration domain. `defdelegate` only — no
  logic here. Owns the `agent_runs` table: the extracted/validated output
  of each run against a given document_job, including history across
  re-runs. See `DocumentComplianceEngine.DocumentJobs` for the ingestion record.
  """

  alias DocumentComplianceEngine.AgentRuns.Actions.{
    CountPendingAudits,
    HandleAgentCallback,
    ListPendingAudits,
    ListReviewedAudits,
    RecordAuditReview,
    ResumeReview,
    TriggerAgentRun
  }

  alias DocumentComplianceEngine.AgentRuns.PubSubTopic
  alias DocumentComplianceEngine.AgentRuns.Repository

  alias DocumentComplianceEngine.AgentRuns.ReviewDecisions.Repository,
    as: ReviewDecisionsRepository

  alias DocumentComplianceEngine.AgentRuns.Workers.TriggerAgentRunWorker

  defdelegate get_latest_for_document_job(document_job_id), to: Repository
  defdelegate latest_by_document_job_ids(ids), to: Repository
  defdelegate enqueue_trigger(document_job_id), to: TriggerAgentRunWorker, as: :enqueue
  defdelegate trigger_agent_run(document_job_id), to: TriggerAgentRun, as: :call
  defdelegate handle_agent_callback(params), to: HandleAgentCallback, as: :call

  defdelegate resume_review(document_job_id, decision, reviewer, rationale),
    to: ResumeReview,
    as: :call

  defdelegate list_review_decisions(document_job_id),
    to: ReviewDecisionsRepository,
    as: :list_for_document_job

  defdelegate count_active(), to: Repository

  defdelegate list_pending_audits(organization_id), to: ListPendingAudits, as: :call

  defdelegate record_audit_review(audit_sample_id, organization_id, decision, reviewer, notes),
    to: RecordAuditReview,
    as: :call

  defdelegate list_reviewed_audits(organization_id, limit \\ 20),
    to: ListReviewedAudits,
    as: :call

  defdelegate count_pending_audits(organization_id), to: CountPendingAudits, as: :call
  defdelegate pubsub_topic(organization_id), to: PubSubTopic, as: :for_organization
end
