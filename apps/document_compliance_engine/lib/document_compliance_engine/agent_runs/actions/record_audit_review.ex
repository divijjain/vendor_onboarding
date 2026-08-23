defmodule DocumentComplianceEngine.AgentRuns.Actions.RecordAuditReview do
  @moduledoc """
  A compliance officer's post-hoc verdict on a sampled auto-approval:
  `:confirmed` (the auto-approval held up) or `:discrepancy` (it
  shouldn't have gone through). Purely a record — deliberately doesn't
  touch `document_jobs` or `agent_runs` status either way, the same
  "out-of-band" boundary `AuditSample`'s moduledoc documents. A found
  discrepancy is a finding for a human to act on, not an automatic
  re-open of the pipeline.

  `audit_sample_id` arrives as a client-submitted form field (unlike
  `ResumeReview`'s `document_job_id`, which only ever comes from a
  LiveView's own already-authorized socket assigns) — so this action
  re-verifies ownership itself, via the sample's document_job, rather
  than trusting whoever's showing the form.
  """

  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.DocumentJobs

  @spec call(
          pos_integer(),
          pos_integer(),
          :confirmed | :discrepancy,
          String.t(),
          String.t() | nil
        ) ::
          {:ok, DocumentComplianceEngine.AgentRuns.AuditSamples.Schema.AuditSample.t()}
          | {:error, :not_found | :already_reviewed | Ecto.Changeset.t()}
  def call(audit_sample_id, organization_id, decision, reviewer, notes)
      when decision in [:confirmed, :discrepancy] do
    with {:ok, audit_sample} <- AuditSamplesRepository.get(audit_sample_id),
         {:ok, _document_job} <-
           DocumentJobs.get_document_job(audit_sample.document_job_id, organization_id),
         :ok <- ensure_pending(audit_sample) do
      AuditSamplesRepository.update_review(audit_sample, %{
        status: decision,
        reviewer: reviewer,
        notes: notes,
        reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end
  end

  defp ensure_pending(%{status: :pending}), do: :ok
  defp ensure_pending(_audit_sample), do: {:error, :already_reviewed}
end
