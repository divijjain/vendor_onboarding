defmodule DocumentComplianceEngine.AgentRuns.Actions.ResumeReviewTest do
  use DocumentComplianceEngine.DataCase, async: true
  use Oban.Testing, repo: DocumentComplianceEngine.Repo

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.Workers.ResumeAgentRunWorker
  alias DocumentComplianceEngine.DocumentJobs

  defp needs_review_document_job(key) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: key,
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: user_fixture().id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    {:ok, _run} =
      AgentRuns.Repository.update_result(run, %{
        status: :needs_review,
        thread_id: "thread-#{document_job.id}"
      })

    {:ok, document_job} = DocumentJobs.update_status(document_job.id, :needs_review)
    document_job
  end

  test "enqueues ResumeAgentRunWorker with the run's thread_id on a :needs_review document_job" do
    document_job = needs_review_document_job("resume-1")

    assert {:ok, returned} =
             AgentRuns.resume_review(
               document_job.id,
               :approved,
               "Jane Reviewer",
               "Looks correct."
             )

    assert returned.id == document_job.id

    assert_enqueued(
      worker: ResumeAgentRunWorker,
      args: %{
        document_job_id: document_job.id,
        thread_id: "thread-#{document_job.id}",
        decision: "approved"
      }
    )
  end

  test "records an audit trail entry with the reviewer, rationale, and evidence snapshot" do
    document_job = needs_review_document_job("resume-audit")

    assert {:ok, _document_job} =
             AgentRuns.resume_review(
               document_job.id,
               :rejected,
               "Jane Reviewer",
               "Names don't match."
             )

    assert [decision] = AgentRuns.list_review_decisions(document_job.id)
    assert decision.decision == :rejected
    assert decision.reviewer == "Jane Reviewer"
    assert decision.rationale == "Names don't match."
    assert decision.thread_id == "thread-#{document_job.id}"
  end

  test "rejects resuming an document_job that isn't :needs_review" do
    {:ok, received} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "resume-2",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: user_fixture().id
      })

    assert {:error, :not_awaiting_review} =
             AgentRuns.resume_review(received.id, :approved, "Jane Reviewer", "Looks correct.")

    refute_enqueued(worker: ResumeAgentRunWorker)
  end

  test "returns {:error, :not_found} for a missing document_job" do
    assert {:error, :not_found} =
             AgentRuns.resume_review(-1, :approved, "Jane Reviewer", "Looks correct.")
  end
end
