defmodule DocumentComplianceEngineWeb.AuditLiveTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.DocumentJobs

  setup %{conn: conn} do
    owner = user_fixture()
    %{conn: log_in_user(conn, owner), owner: owner}
  end

  defp insert_pending_sample(owner) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "audit-live-#{System.unique_integer([:positive])}",
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

    sample
  end

  test "redirects to / when not signed in" do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/audits")
  end

  test "lists a pending sample and lets the owner confirm it", %{conn: conn, owner: owner} do
    sample = insert_pending_sample(owner)

    {:ok, view, html} = live(conn, ~p"/audits")
    assert html =~ "Acme Corp"

    html =
      view
      |> form("#audit-form-#{sample.id}", %{reviewer: "Jane", notes: "Looks fine."})
      |> render_submit(%{"decision" => "confirmed"})

    assert html =~ "Audit recorded."
    assert html =~ "Recently audited"

    assert {:ok, updated} = AuditSamplesRepository.get(sample.id)
    assert updated.status == :confirmed
    assert updated.reviewer == "Jane"
  end

  test "never shows another organization's pending sample", %{conn: conn} do
    _theirs = insert_pending_sample(user_fixture())

    {:ok, _view, html} = live(conn, ~p"/audits")
    assert html =~ "No samples awaiting audit."
  end
end
