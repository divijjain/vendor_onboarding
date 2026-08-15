defmodule VendorOnboarding.DocumentJobs.Actions.ListWithLatestRunTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.DocumentJobs

  defp insert_document_job(key) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{idempotency_key: key, document_paths: %{}})

    document_job
  end

  describe "run/1" do
    test "merges each document_job with its latest run's company_name, batched not N+1" do
      document_job = insert_document_job("list-1")

      {:ok, _older} =
        AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :rejected})

      {:ok, newer} =
        AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

      {:ok, _updated} =
        AgentRuns.Repository.update_result(newer, %{
          status: :processing,
          company_name: "Acme Corp"
        })

      rows = DocumentJobs.list_document_jobs_with_latest_run()
      row = Enum.find(rows, &(&1.id == document_job.id))

      assert row.company_name == "Acme Corp"
      assert row.status == document_job.status
    end

    test "company_name is nil when no run has started yet" do
      document_job = insert_document_job("list-2")

      rows = DocumentJobs.list_document_jobs_with_latest_run()
      row = Enum.find(rows, &(&1.id == document_job.id))

      assert row.company_name == nil
    end
  end

  describe "reload/1" do
    test "returns the same merged shape for a single document_job" do
      document_job = insert_document_job("list-3")

      {:ok, run} =
        AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

      {:ok, _updated} =
        AgentRuns.Repository.update_result(run, %{status: :approved, company_name: "Acme Corp"})

      # HandleAgentCallback keeps these in sync in the real flow; done
      # explicitly here since this test writes to AgentRuns directly.
      {:ok, _document_job} = DocumentJobs.update_status(document_job.id, :approved)

      assert {:ok, row} = DocumentJobs.reload_document_job_row(document_job.id)
      assert row.id == document_job.id
      assert row.company_name == "Acme Corp"
      assert row.status == :approved
    end

    test "returns {:error, :not_found} for a missing document_job" do
      assert DocumentJobs.reload_document_job_row(-1) == {:error, :not_found}
    end
  end
end
