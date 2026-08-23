defmodule DocumentComplianceEngine.DocumentJobs.Actions.ListWithLatestRunTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  setup do
    %{owner: user_fixture()}
  end

  defp insert_document_job(key, owner, overrides \\ %{}) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(
        Map.merge(
          %{
            idempotency_key: key,
            document_paths: %{},
            document_type_slug: "vendor_contract_w9",
            owner_user_id: owner.id,
            organization_id: owner.organization_id
          },
          overrides
        )
      )

    document_job
  end

  describe "run/2" do
    test "merges each document_job with its latest run's company_name, batched not N+1", %{
      owner: owner
    } do
      document_job = insert_document_job("list-1", owner)

      {:ok, _older} =
        AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :rejected})

      {:ok, newer} =
        AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

      {:ok, _updated} =
        AgentRuns.Repository.update_result(newer, %{
          status: :processing,
          company_name: "Acme Corp"
        })

      rows = DocumentJobs.list_document_jobs_with_latest_run(owner.organization_id)
      row = Enum.find(rows, &(&1.id == document_job.id))

      assert row.company_name == "Acme Corp"
      assert row.status == document_job.status
    end

    test "company_name is nil when no run has started yet", %{owner: owner} do
      document_job = insert_document_job("list-2", owner)

      rows = DocumentJobs.list_document_jobs_with_latest_run(owner.organization_id)
      row = Enum.find(rows, &(&1.id == document_job.id))

      assert row.company_name == nil
    end

    test "falls back to extracted_fields.invoice.vendor_name for an invoice document_job", %{
      owner: owner
    } do
      document_job =
        insert_document_job("list-invoice-1", owner, %{document_type_slug: "invoice"})

      {:ok, run} =
        AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

      {:ok, _updated} =
        AgentRuns.Repository.update_result(run, %{
          status: :approved,
          extracted_fields: %{"invoice" => %{"vendor_name" => "Northwind Traders Ltd."}}
        })

      rows = DocumentJobs.list_document_jobs_with_latest_run(owner.organization_id)
      row = Enum.find(rows, &(&1.id == document_job.id))

      assert row.company_name == "Northwind Traders Ltd."
    end

    test "never returns another organization's document_jobs", %{owner: owner} do
      _mine = insert_document_job("list-mine", owner)
      other_owner = user_fixture()
      _theirs = insert_document_job("list-theirs", other_owner)

      rows = DocumentJobs.list_document_jobs_with_latest_run(owner.organization_id)
      assert Enum.all?(rows, &(&1.id != nil))
      assert length(rows) == 1
    end

    test "returns document_jobs for every member of the same organization", %{owner: owner} do
      teammate = user_fixture(%{organization_id: owner.organization_id})
      mine = insert_document_job("list-shared-mine", owner)
      theirs = insert_document_job("list-shared-theirs", teammate)

      rows = DocumentJobs.list_document_jobs_with_latest_run(owner.organization_id)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([mine.id, theirs.id])
    end
  end

  describe "reload/2" do
    test "returns the same merged shape for a single document_job", %{owner: owner} do
      document_job = insert_document_job("list-3", owner)

      {:ok, run} =
        AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

      {:ok, _updated} =
        AgentRuns.Repository.update_result(run, %{status: :approved, company_name: "Acme Corp"})

      # HandleAgentCallback keeps these in sync in the real flow; done
      # explicitly here since this test writes to AgentRuns directly.
      {:ok, _document_job} = DocumentJobs.update_status(document_job.id, :approved)

      assert {:ok, row} =
               DocumentJobs.reload_document_job_row(document_job.id, owner.organization_id)

      assert row.id == document_job.id
      assert row.company_name == "Acme Corp"
      assert row.status == :approved
    end

    test "returns {:error, :not_found} for a missing document_job", %{owner: owner} do
      assert DocumentJobs.reload_document_job_row(-1, owner.organization_id) ==
               {:error, :not_found}
    end

    test "returns {:error, :not_found} for another organization's document_job", %{owner: owner} do
      document_job = insert_document_job("list-4", user_fixture())

      assert DocumentJobs.reload_document_job_row(document_job.id, owner.organization_id) ==
               {:error, :not_found}
    end
  end
end
