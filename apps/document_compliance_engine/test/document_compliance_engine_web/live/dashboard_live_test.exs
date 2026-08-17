defmodule DocumentComplianceEngineWeb.DashboardLiveTest do
  # async: false — one test stubs :system_health_mcp_check_fun, shared
  # Application env also touched by SystemHealthTest.
  use DocumentComplianceEngineWeb.ConnCase, async: false

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  defp insert_document_job(key) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: key,
        document_paths: %{},
        document_type_slug: "vendor_contract_w9"
      })

    document_job
  end

  defp mark_needs_review(document_job) do
    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    {:ok, _run} =
      AgentRuns.Repository.update_result(run, %{status: :needs_review, thread_id: "t-1"})

    {:ok, document_job} = DocumentJobs.update_status(document_job.id, :needs_review)
    document_job
  end

  test "lists document_jobs with a status badge, and every row links out (labeled by status)",
       %{conn: conn} do
    received = insert_document_job("dash-received")
    needs_review = "dash-needs-review" |> insert_document_job() |> mark_needs_review()

    {:ok, view, html} = live(conn, ~p"/document_jobs")

    # Scoped to this row, not a bare `=~ "Needs review"` — the summary
    # stats panel always has a "Needs review" stat-title label regardless
    # of any row's actual status.
    assert has_element?(view, "#document_jobs-#{needs_review.id} .badge-warning")
    assert html =~ ~p"/document_jobs/#{needs_review.id}"
    assert has_element?(view, "#document_jobs-#{needs_review.id} a", "Review")

    # Every row links out — not just needs_review — since the review page
    # now also shows the original stored documents, useful regardless of
    # whether this document_job is still awaiting a decision.
    assert html =~ ~p"/document_jobs/#{received.id}"
    assert has_element?(view, "#document_jobs-#{received.id} a", "View")
  end

  test "filters the list by document type", %{conn: conn} do
    invoice_type = DocumentComplianceEngine.DocumentTypes.Repository.get_by_slug("invoice")

    default = insert_document_job("dash-filter-default")

    {:ok, invoice} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "dash-filter-invoice",
        document_paths: %{},
        document_type_slug: invoice_type.slug
      })

    {:ok, view, html} = live(conn, ~p"/document_jobs")
    assert html =~ "id=\"document_jobs-#{default.id}\""
    assert html =~ "id=\"document_jobs-#{invoice.id}\""

    filtered =
      view
      |> form("#document-type-filter", %{document_type_slug: "invoice"})
      |> render_change()

    refute filtered =~ "id=\"document_jobs-#{default.id}\""
    assert filtered =~ "id=\"document_jobs-#{invoice.id}\""
  end

  test "renders the system health panel", %{conn: conn} do
    # Stubbed rather than relying on the MCP servers being absent — on a
    # dev machine that's actually running them (per the README's local-dev
    # steps), this test would otherwise depend on ambient system state
    # instead of being hermetic.
    Application.put_env(:document_compliance_engine, :system_health_mcp_check_fun, fn _url ->
      {:error, :econnrefused}
    end)

    on_exit(fn ->
      Application.delete_env(:document_compliance_engine, :system_health_mcp_check_fun)
    end)

    {:ok, _view, html} = live(conn, ~p"/document_jobs")

    assert html =~ "BEAM processes"
    assert html =~ "Oban queue depth"
    assert html =~ "Active agent runs"
    assert html =~ "Tax API MCP"
    assert html =~ "Sanctions DB MCP"
    assert html =~ "down"
  end

  test "reacts to a PubSub status update by reloading just that row", %{conn: conn} do
    document_job = insert_document_job("dash-pubsub")

    row = "#document_jobs-#{document_job.id}"

    {:ok, view, html} = live(conn, ~p"/document_jobs")
    assert html =~ "Received"
    # Scoped to this row, not a bare `render(view) =~ "Approved"` — the
    # summary stats panel always has an "Approved" stat-title label
    # regardless of any row's actual status, and a shared-sandbox test run
    # can have other rows present too.
    refute has_element?(view, "#{row} .badge-success")

    {:ok, _updated} = DocumentJobs.update_status(document_job.id, :approved)

    Phoenix.PubSub.broadcast(
      DocumentComplianceEngine.PubSub,
      "document_compliance_engine",
      {:status_updated, document_job.id}
    )

    assert has_element?(view, "#{row} .badge-success")
  end

  test "submitting the manual upload form ingests a document_job the same way a webhook does",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/document_jobs")

    view
    |> form("#manual-upload-form", %{document_type_slug: "invoice"})
    |> render_change()

    avatar =
      file_input(view, "#manual-upload-form", :invoice, [
        %{name: "invoice.txt", content: "INVOICE #1234, vendor Acme Corp", type: "text/plain"}
      ])

    assert render_upload(avatar, "invoice.txt") =~ "invoice.txt"

    html =
      view
      |> form("#manual-upload-form", %{document_type_slug: "invoice"})
      |> render_submit()

    assert html =~ "submitted"

    assert [%{document_type_slug: "invoice"}] =
             DocumentJobs.list_document_jobs(document_type_slug: "invoice")
  end

  test "submitting the manual upload form without every required file shows an error",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/document_jobs")

    html =
      view
      |> form("#manual-upload-form", %{document_type_slug: "vendor_contract_w9"})
      |> render_submit()

    assert html =~ "Select a document type and a file for every required document"
  end
end
