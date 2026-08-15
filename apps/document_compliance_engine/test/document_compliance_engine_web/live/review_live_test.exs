defmodule DocumentComplianceEngineWeb.ReviewLiveTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  defp needs_review_document_job do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-#{System.unique_integer([:positive])}",
        document_paths: %{}
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    {:ok, _run} =
      AgentRuns.Repository.update_result(run, %{
        status: :needs_review,
        thread_id: "document_job-#{document_job.id}",
        company_name: "Acme Corp",
        w9_company_name: "Totally Different LLC",
        tax_id: "12-3456789",
        payment_terms: "Net 30",
        liability_clauses: "Standard.",
        explanation: "Names do not match."
      })

    DocumentJobs.update_status(document_job.id, :needs_review)
  end

  test "shows the side-by-side contract/W-9 diff and the drafted explanation", %{conn: conn} do
    {:ok, document_job} = needs_review_document_job()

    {:ok, _view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    assert html =~ "Acme Corp"
    assert html =~ "Totally Different LLC"
    assert html =~ "12-3456789"
    assert html =~ "Names do not match."
    assert html =~ "Approve"
    assert html =~ "Reject"
  end

  test "approve calls resume_review and shows a flash", %{conn: conn} do
    {:ok, document_job} = needs_review_document_job()

    {:ok, view, _html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    html = view |> element("button", "Approve") |> render_click()
    assert html =~ "waiting for the agent to resume"
  end

  test "hides approve/reject once no longer awaiting review", %{conn: conn} do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{idempotency_key: "review-approved", document_paths: %{}})

    {:ok, document_job} = DocumentJobs.update_status(document_job.id, :approved)

    {:ok, _view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    refute html =~ "Approve"
    assert html =~ "no longer awaiting review"
  end
end
