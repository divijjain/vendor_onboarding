defmodule DocumentComplianceEngine.DocumentJobsTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.DocumentJobs

  test "get_document_job/1 delegates to the repository" do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{idempotency_key: "ctx-1", document_paths: %{}})

    assert {:ok, found} = DocumentJobs.get_document_job(document_job.id)
    assert found.id == document_job.id
    assert DocumentJobs.get_document_job(-1) == {:error, :not_found}
  end

  test "list_document_jobs/1 delegates to the repository" do
    {:ok, _document_job} =
      DocumentJobs.Repository.insert(%{idempotency_key: "ctx-2", document_paths: %{}})

    assert [_ | _] = DocumentJobs.list_document_jobs()
  end
end
