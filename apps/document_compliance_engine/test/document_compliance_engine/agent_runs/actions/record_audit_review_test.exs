defmodule DocumentComplianceEngine.AgentRuns.Actions.RecordAuditReviewTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.DocumentJobs

  defp insert_pending_sample(owner) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "audit-review-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :approved})

    {:ok, sample} =
      AuditSamplesRepository.insert(%{
        document_job_id: document_job.id,
        agent_run_id: run.id,
        status: :pending
      })

    sample
  end

  test "records a :confirmed outcome" do
    owner = user_fixture()
    sample = insert_pending_sample(owner)

    assert {:ok, updated} =
             AgentRuns.record_audit_review(
               sample.id,
               owner.organization_id,
               :confirmed,
               "Jane",
               "Checked out fine."
             )

    assert updated.status == :confirmed
    assert updated.reviewer == "Jane"
    assert updated.notes == "Checked out fine."
    assert updated.reviewed_at
  end

  test "records a :discrepancy outcome" do
    owner = user_fixture()
    sample = insert_pending_sample(owner)

    assert {:ok, updated} =
             AgentRuns.record_audit_review(
               sample.id,
               owner.organization_id,
               :discrepancy,
               "Jane",
               "Should have flagged."
             )

    assert updated.status == :discrepancy
  end

  test "a teammate in the same organization can record the review" do
    owner = user_fixture()
    teammate = user_fixture(%{organization_id: owner.organization_id})
    sample = insert_pending_sample(owner)

    assert {:ok, updated} =
             AgentRuns.record_audit_review(
               sample.id,
               teammate.organization_id,
               :confirmed,
               "Teammate",
               nil
             )

    assert updated.status == :confirmed
  end

  test "rejects reviewing an already-reviewed sample" do
    owner = user_fixture()
    sample = insert_pending_sample(owner)

    {:ok, _} =
      AgentRuns.record_audit_review(sample.id, owner.organization_id, :confirmed, "Jane", nil)

    assert {:error, :already_reviewed} =
             AgentRuns.record_audit_review(
               sample.id,
               owner.organization_id,
               :discrepancy,
               "Someone else",
               nil
             )
  end

  test "returns {:error, :not_found} for a missing sample" do
    assert {:error, :not_found} =
             AgentRuns.record_audit_review(
               -1,
               user_fixture().organization_id,
               :confirmed,
               "Jane",
               nil
             )
  end

  test "returns {:error, :not_found} when the sample belongs to a different organization" do
    owner = user_fixture()
    sample = insert_pending_sample(owner)
    other_owner = user_fixture()

    assert {:error, :not_found} =
             AgentRuns.record_audit_review(
               sample.id,
               other_owner.organization_id,
               :confirmed,
               "Intruder",
               nil
             )
  end
end
