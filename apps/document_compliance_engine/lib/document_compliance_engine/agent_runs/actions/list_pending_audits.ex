defmodule DocumentComplianceEngine.AgentRuns.Actions.ListPendingAudits do
  @moduledoc """
  Read model for the audit queue LiveView: pending `audit_samples` merged
  with the document_job and agent_run each one refers to, scoped to a
  single organization — the audit queue is siloed per-organization just
  like `document_jobs` itself, not a shared compliance-officer view
  across every business customer. Batches both lookups (no N+1) the same
  way `DocumentJobs.Actions.ListWithLatestRun` batches `AgentRuns` for
  the dashboard. `audit_samples`/`agent_runs` carry no organization
  column of their own — authorization here is transitive through each
  sample's document_job.
  """

  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.AgentRuns.Repository, as: AgentRunsRepository
  alias DocumentComplianceEngine.DocumentJobs

  @spec call(pos_integer()) :: [map()]
  def call(organization_id) do
    audit_samples = AuditSamplesRepository.list_pending()
    merge(audit_samples, organization_id)
  end

  defp merge([], _organization_id), do: []

  defp merge(audit_samples, organization_id) do
    document_jobs_by_id =
      audit_samples
      |> Enum.map(& &1.document_job_id)
      |> Enum.uniq()
      |> DocumentJobs.get_document_jobs_by_ids()

    agent_runs_by_id =
      audit_samples
      |> Enum.map(& &1.agent_run_id)
      |> Enum.uniq()
      |> AgentRunsRepository.get_by_ids()

    for audit_sample <- audit_samples,
        document_job = document_jobs_by_id[audit_sample.document_job_id],
        agent_run = agent_runs_by_id[audit_sample.agent_run_id],
        not is_nil(document_job) and not is_nil(agent_run),
        document_job.organization_id == organization_id do
      %{
        audit_sample: audit_sample,
        document_job: document_job,
        agent_run: agent_run
      }
    end
  end
end
