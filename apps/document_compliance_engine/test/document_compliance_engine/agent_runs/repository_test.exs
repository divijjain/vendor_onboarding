defmodule DocumentComplianceEngine.AgentRuns.RepositoryTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.AgentRuns.Repository
  alias DocumentComplianceEngine.DocumentJobs.Repository, as: DocumentJobsRepository

  defp insert_document_job(key) do
    {:ok, document_job} =
      DocumentJobsRepository.insert(%{
        idempotency_key: key,
        document_paths: %{},
        document_type_slug: "vendor_contract_w9"
      })

    document_job
  end

  describe "insert/1" do
    test "starts a run with status :processing" do
      document_job = insert_document_job("run-1")

      assert {:ok, run} =
               Repository.insert(%{document_job_id: document_job.id, status: :processing})

      assert run.status == :processing
      assert run.document_job_id == document_job.id
    end
  end

  describe "update_result/2" do
    test "writes back status, thread_id, and encrypted tax_id" do
      document_job = insert_document_job("run-2")
      {:ok, run} = Repository.insert(%{document_job_id: document_job.id, status: :processing})

      assert {:ok, updated} =
               Repository.update_result(run, %{
                 status: :needs_review,
                 thread_id: "thread-1",
                 company_name: "Acme Corp",
                 w9_company_name: "Acme Corporation",
                 tax_id: "12-3456789",
                 payment_terms: "Net 30",
                 liability_clauses: "Standard indemnification clause.",
                 explanation: "Names differ."
               })

      assert updated.status == :needs_review
      assert updated.thread_id == "thread-1"
      assert updated.tax_id == "12-3456789"
    end

    test "persists tax_id encrypted at rest, not as plaintext" do
      document_job = insert_document_job("run-3")
      {:ok, run} = Repository.insert(%{document_job_id: document_job.id, status: :processing})

      {:ok, _updated} = Repository.update_result(run, %{status: :approved, tax_id: "12-3456789"})

      %{rows: [[raw_binary]]} =
        Ecto.Adapters.SQL.query!(
          DocumentComplianceEngine.Repo,
          "SELECT tax_id FROM agent_runs WHERE id = $1",
          [run.id]
        )

      refute raw_binary == "12-3456789"
    end
  end

  describe "get_latest_for_document_job/1" do
    test "returns the most recently inserted run" do
      document_job = insert_document_job("run-4")
      {:ok, _older} = Repository.insert(%{document_job_id: document_job.id, status: :rejected})

      {:ok, newer} =
        Repository.insert(%{document_job_id: document_job.id, status: :processing})

      assert {:ok, found} = Repository.get_latest_for_document_job(document_job.id)
      assert found.id == newer.id
    end

    test "returns {:error, :not_found} when no run exists" do
      document_job = insert_document_job("run-5")
      assert Repository.get_latest_for_document_job(document_job.id) == {:error, :not_found}
    end
  end

  describe "latest_by_document_job_ids/1" do
    test "batches the latest run per document_job id" do
      a = insert_document_job("run-6a")
      b = insert_document_job("run-6b")

      {:ok, _a_old} = Repository.insert(%{document_job_id: a.id, status: :rejected})
      {:ok, a_new} = Repository.insert(%{document_job_id: a.id, status: :approved})
      {:ok, b_run} = Repository.insert(%{document_job_id: b.id, status: :processing})

      result = Repository.latest_by_document_job_ids([a.id, b.id])

      assert result[a.id].id == a_new.id
      assert result[b.id].id == b_run.id
    end
  end

  describe "count_active/0" do
    test "counts only :processing runs" do
      a = insert_document_job("run-7a")
      b = insert_document_job("run-7b")
      c = insert_document_job("run-7c")

      {:ok, _} = Repository.insert(%{document_job_id: a.id, status: :processing})
      {:ok, _} = Repository.insert(%{document_job_id: b.id, status: :processing})
      {:ok, _} = Repository.insert(%{document_job_id: c.id, status: :approved})

      assert Repository.count_active() == 2
    end

    test "returns 0 when no runs are active" do
      assert Repository.count_active() == 0
    end
  end
end
