defmodule DocumentComplianceEngineWeb.ReviewLiveTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true
  use Oban.Testing, repo: DocumentComplianceEngine.Repo

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.Workers.TriggerAgentRunWorker
  alias DocumentComplianceEngine.DocumentJobs

  defp failed_document_job do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-failed-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9"
      })

    DocumentJobs.update_status(document_job.id, :failed)
  end

  defp needs_review_document_job do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9"
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
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-approved",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9"
      })

    {:ok, document_job} = DocumentJobs.update_status(document_job.id, :approved)

    {:ok, _view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    # Not a plain `refute html =~ "Approve"` — the (now humanized) "Approved"
    # status badge legitimately contains "Approve" as a substring.
    refute html =~ ~s(phx-click="approve")
    assert html =~ "no longer awaiting review"
  end

  test "shows the original stored documents alongside the extracted fields", %{conn: conn} do
    contract_text = "contract-#{System.unique_integer([:positive])}"
    w9_text = "w9-#{System.unique_integer([:positive])}"

    payload =
      Jason.encode!(%{
        "document_type_slug" => "vendor_contract_w9",
        "documents" => %{
          "contract" => Base.encode64(contract_text),
          "w9" => Base.encode64(w9_text)
        }
      })

    {:ok, document_job} = DocumentJobs.ingest_webhook(payload)

    on_exit(fn ->
      document_job.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)

    {:ok, _view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    assert html =~ contract_text
    assert html =~ w9_text
  end

  test "shows a retry button for a failed run, and retrying enqueues the agent run again",
       %{conn: conn} do
    {:ok, document_job} = failed_document_job()

    {:ok, view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")
    assert html =~ ~s(phx-click="retry")
    refute html =~ "no longer awaiting review"

    html = view |> element("button", "Retry") |> render_click()
    assert html =~ "Retry queued"

    assert_enqueued(worker: TriggerAgentRunWorker, args: %{document_job_id: document_job.id})
  end
end
