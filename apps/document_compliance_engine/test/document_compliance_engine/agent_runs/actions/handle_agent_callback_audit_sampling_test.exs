defmodule DocumentComplianceEngine.AgentRuns.Actions.HandleAgentCallbackAuditSamplingTest do
  use DocumentComplianceEngine.DataCase, async: false

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.DocumentJobs

  defp insert_document_job_with_run(key) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: key,
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: user_fixture().id
      })

    {:ok, _run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    document_job
  end

  defp put_sample_rate(rate) do
    Application.put_env(:document_compliance_engine, :audit_sample_rate, rate)
    on_exit(fn -> Application.put_env(:document_compliance_engine, :audit_sample_rate, 0.0) end)
  end

  test "a fully-automated approval is eligible for audit sampling" do
    put_sample_rate(1.0)
    document_job = insert_document_job_with_run("cb-audit-1")

    assert {:ok, updated_run} =
             AgentRuns.handle_agent_callback(%{
               "document_job_id" => document_job.id,
               "status" => "approved",
               "company_name" => "Acme Corp"
             })

    assert [sample] = AuditSamplesRepository.list_pending()
    assert sample.agent_run_id == updated_run.id
    assert sample.document_job_id == document_job.id
  end

  test "a halted-then-resumed approval (has a thread_id) is not eligible" do
    put_sample_rate(1.0)
    document_job = insert_document_job_with_run("cb-audit-2")

    assert {:ok, _updated_run} =
             AgentRuns.handle_agent_callback(%{
               "document_job_id" => document_job.id,
               "status" => "approved",
               "thread_id" => "thread-cb-audit-2"
             })

    assert AuditSamplesRepository.list_pending() == []
  end

  test "a :needs_review callback is never sampled" do
    put_sample_rate(1.0)
    document_job = insert_document_job_with_run("cb-audit-3")

    assert {:ok, _updated_run} =
             AgentRuns.handle_agent_callback(%{
               "document_job_id" => document_job.id,
               "status" => "needs_review",
               "thread_id" => "thread-cb-audit-3"
             })

    assert AuditSamplesRepository.list_pending() == []
  end
end
