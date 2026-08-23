defmodule DocumentComplianceEngine.AgentRuns.Actions.ListPendingAuditsTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.DocumentJobs

  test "merges each pending sample with its document_job and agent_run" do
    owner = user_fixture()

    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "list-pending-audits-1",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    {:ok, run} =
      AgentRuns.Repository.update_result(run, %{status: :approved, company_name: "Acme Corp"})

    {:ok, sample} =
      AuditSamplesRepository.insert(%{
        document_job_id: document_job.id,
        agent_run_id: run.id,
        status: :pending
      })

    assert [row] = AgentRuns.list_pending_audits(owner.organization_id)
    assert row.audit_sample.id == sample.id
    assert row.document_job.id == document_job.id
    assert row.agent_run.id == run.id
    assert row.agent_run.company_name == "Acme Corp"
  end

  test "never returns another organization's pending sample" do
    owner = user_fixture()
    other_owner = user_fixture()

    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "list-pending-audits-2",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: other_owner.id,
        organization_id: other_owner.organization_id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :approved})

    {:ok, _sample} =
      AuditSamplesRepository.insert(%{
        document_job_id: document_job.id,
        agent_run_id: run.id,
        status: :pending
      })

    assert AgentRuns.list_pending_audits(owner.organization_id) == []
  end

  test "returns pending samples for every member of the same organization" do
    owner = user_fixture()
    teammate = user_fixture(%{organization_id: owner.organization_id})

    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "list-pending-audits-3",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: teammate.id,
        organization_id: teammate.organization_id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :approved})

    {:ok, sample} =
      AuditSamplesRepository.insert(%{
        document_job_id: document_job.id,
        agent_run_id: run.id,
        status: :pending
      })

    assert [row] = AgentRuns.list_pending_audits(owner.organization_id)
    assert row.audit_sample.id == sample.id
  end

  test "returns an empty list when there's nothing pending" do
    assert AgentRuns.list_pending_audits(user_fixture().organization_id) == []
  end
end
