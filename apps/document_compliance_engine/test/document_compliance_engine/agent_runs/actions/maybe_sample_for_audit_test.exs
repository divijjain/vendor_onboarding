defmodule DocumentComplianceEngine.AgentRuns.Actions.MaybeSampleForAuditTest do
  use DocumentComplianceEngine.DataCase, async: false

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.Actions.MaybeSampleForAudit
  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.DocumentJobs

  defp put_sample_rate(rate) do
    Application.put_env(:document_compliance_engine, :audit_sample_rate, rate)
    on_exit(fn -> Application.put_env(:document_compliance_engine, :audit_sample_rate, 0.0) end)
  end

  defp insert_run(key, attrs) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: key,
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: user_fixture().id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    {:ok, run} = AgentRuns.Repository.update_result(run, attrs)
    run
  end

  test "samples a straight-through approval (no thread_id) when the rate guarantees it" do
    put_sample_rate(1.0)
    run = insert_run("audit-1", %{status: :approved, company_name: "Acme Corp"})

    assert :ok = MaybeSampleForAudit.call(run)

    assert [sample] = AuditSamplesRepository.list_pending()
    assert sample.agent_run_id == run.id
    assert sample.document_job_id == run.document_job_id
    assert sample.status == :pending
  end

  test "never samples when the rate guarantees it won't" do
    put_sample_rate(0.0)
    run = insert_run("audit-2", %{status: :approved})

    assert :ok = MaybeSampleForAudit.call(run)
    assert AuditSamplesRepository.list_pending() == []
  end

  test "does not sample an approval that came from a human resume (thread_id present)" do
    put_sample_rate(1.0)
    run = insert_run("audit-3", %{status: :approved, thread_id: "thread-audit-3"})

    assert :ok = MaybeSampleForAudit.call(run)
    assert AuditSamplesRepository.list_pending() == []
  end

  test "does not sample a run that isn't :approved" do
    put_sample_rate(1.0)
    run = insert_run("audit-4", %{status: :needs_review, thread_id: "thread-audit-4"})

    assert :ok = MaybeSampleForAudit.call(run)
    assert AuditSamplesRepository.list_pending() == []
  end
end
