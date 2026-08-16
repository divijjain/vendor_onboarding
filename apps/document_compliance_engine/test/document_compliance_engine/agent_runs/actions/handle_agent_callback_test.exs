defmodule DocumentComplianceEngine.AgentRuns.Actions.HandleAgentCallbackTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  defp insert_document_job_with_run(key) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: key,
        document_paths: %{},
        document_type_slug: "vendor_contract_w9"
      })

    {:ok, _run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    document_job
  end

  test "writes back the run's result, mirrors status onto the document_job, and broadcasts PubSub" do
    document_job = insert_document_job_with_run("cb-1")
    document_job_id = document_job.id

    Phoenix.PubSub.subscribe(DocumentComplianceEngine.PubSub, "document_compliance_engine")

    assert {:ok, updated_run} =
             AgentRuns.handle_agent_callback(%{
               "document_job_id" => document_job.id,
               "status" => "needs_review",
               "thread_id" => "thread-abc",
               "company_name" => "Acme Corp",
               "explanation" => "Names differ."
             })

    assert updated_run.status == :needs_review
    assert updated_run.thread_id == "thread-abc"
    assert updated_run.company_name == "Acme Corp"

    assert {:ok, updated_document_job} = DocumentJobs.get_document_job(document_job.id)
    assert updated_document_job.status == :needs_review

    # Other concurrently-running async tests broadcast on this same topic, so
    # pin the id we care about rather than asserting on whatever arrives first.
    assert_received {:status_updated, ^document_job_id}
  end

  test "accepts a :failed status so a crashed agent run surfaces instead of hanging forever" do
    document_job = insert_document_job_with_run("cb-3")

    assert {:ok, updated_run} =
             AgentRuns.handle_agent_callback(%{
               "document_job_id" => document_job.id,
               "status" => "failed",
               "explanation" => "Agent run failed: OpenAIError: Missing credentials."
             })

    assert updated_run.status == :failed

    assert {:ok, updated_document_job} = DocumentJobs.get_document_job(document_job.id)
    assert updated_document_job.status == :failed
  end

  test "returns {:error, :not_found} when no run has started for that document_job" do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "cb-2",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9"
      })

    assert {:error, :not_found} =
             AgentRuns.handle_agent_callback(%{
               "document_job_id" => document_job.id,
               "status" => "approved"
             })
  end
end
