defmodule DocumentComplianceEngineWeb.ReviewLiveTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true
  use Oban.Testing, repo: DocumentComplianceEngine.Repo

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.Workers.TriggerAgentRunWorker
  alias DocumentComplianceEngine.DocumentJobs

  setup %{conn: conn} do
    owner = user_fixture()
    %{conn: log_in_user(conn, owner), owner: owner}
  end

  defp failed_document_job(owner) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-failed-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    DocumentJobs.update_status(document_job.id, :failed)
  end

  defp needs_review_document_job(owner) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
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

  test "shows the side-by-side contract/W-9 diff and the drafted explanation", %{
    conn: conn,
    owner: owner
  } do
    {:ok, document_job} = needs_review_document_job(owner)

    {:ok, _view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    assert html =~ "Acme Corp"
    assert html =~ "Totally Different LLC"
    assert html =~ "12-3456789"
    assert html =~ "Names do not match."
    assert html =~ "Approve"
    assert html =~ "Reject"
  end

  test "shows confidence and source-quote grounding per extracted field", %{
    conn: conn,
    owner: owner
  } do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-confidence-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    {:ok, _run} =
      AgentRuns.Repository.update_result(run, %{
        status: :needs_review,
        thread_id: "document_job-#{document_job.id}",
        company_name: "Acme Corp",
        explanation: "Names do not match.",
        extraction_metadata: %{
          "contract" => %{
            "company_name" => %{"confidence" => 0.92, "source_quote" => "Acme Corp Inc."}
          },
          "w9" => %{
            "company_name" => %{"confidence" => 0.4, "source_quote" => "Acme Corp"}
          }
        }
      })

    {:ok, document_job} = DocumentJobs.update_status(document_job.id, :needs_review)

    {:ok, _view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    assert html =~ "Extraction confidence"
    assert html =~ "92% confidence"
    assert html =~ "Acme Corp Inc."
    # Below the low-confidence threshold — rendered distinctly, not hidden.
    assert html =~ "40% confidence"
  end

  test "approve calls resume_review, records an audit entry, and shows a flash", %{
    conn: conn,
    owner: owner
  } do
    {:ok, document_job} = needs_review_document_job(owner)

    {:ok, view, _html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    html =
      view
      |> form("#review-decision-form", %{reviewer: "Jane Reviewer", rationale: "Looks correct."})
      |> render_submit(%{"decision" => "approved"})

    assert html =~ "waiting for the agent to resume"
    assert html =~ "Jane Reviewer"
    assert html =~ "Looks correct."

    assert [decision] = AgentRuns.list_review_decisions(document_job.id)
    assert decision.decision == :approved
    assert decision.reviewer == "Jane Reviewer"
    assert decision.rationale == "Looks correct."
    assert decision.evidence == "Names do not match."
  end

  test "hides approve/reject once no longer awaiting review", %{conn: conn, owner: owner} do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "review-approved",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    {:ok, document_job} = DocumentJobs.update_status(document_job.id, :approved)

    {:ok, _view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")

    refute html =~ ~s(id="review-decision-form")
    assert html =~ "no longer awaiting review"
  end

  test "shows the original stored documents alongside the extracted fields", %{
    conn: conn,
    owner: owner
  } do
    contract_text = "contract-#{System.unique_integer([:positive])}"
    w9_text = "w9-#{System.unique_integer([:positive])}"

    payload =
      Jason.encode!(%{
        "document_type_slug" => "vendor_contract_w9",
        "documents" => %{
          "contract" => Base.encode64(contract_text),
          "w9" => Base.encode64(w9_text)
        },
        "owner_email" => owner.email
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
       %{conn: conn, owner: owner} do
    {:ok, document_job} = failed_document_job(owner)

    {:ok, view, html} = live(conn, ~p"/document_jobs/#{document_job.id}")
    assert html =~ ~s(phx-click="retry")
    refute html =~ "no longer awaiting review"

    html = view |> element("button", "Retry") |> render_click()
    assert html =~ "Retry queued"

    assert_enqueued(worker: TriggerAgentRunWorker, args: %{document_job_id: document_job.id})
  end

  test "a document_job belonging to another organization 404s instead of leaking data", %{
    conn: conn
  } do
    {:ok, document_job} = needs_review_document_job(user_fixture())

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/document_jobs/#{document_job.id}")
    end
  end
end
