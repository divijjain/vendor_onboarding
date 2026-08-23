defmodule DocumentComplianceEngine.AgentRuns.Actions.ListReviewedAudits do
  @moduledoc """
  Organization-scoped audit history for the audit queue LiveView — unlike
  the pending queue (naturally small, fetched whole then filtered), this
  is an append-only history that can grow across every organization over
  time, so it's filtered at the SQL level: resolve the organization's own
  document_job ids first via `DocumentJobs`'s public API, then ask
  `AuditSamples.Repository` for only the reviewed samples against that
  id set.
  """

  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.DocumentJobs

  @spec call(pos_integer(), non_neg_integer()) ::
          [DocumentComplianceEngine.AgentRuns.AuditSamples.Schema.AuditSample.t()]
  def call(organization_id, limit \\ 20) do
    document_job_ids = DocumentJobs.list_document_job_ids_for_organization(organization_id)
    AuditSamplesRepository.list_reviewed(document_job_ids, limit)
  end
end
