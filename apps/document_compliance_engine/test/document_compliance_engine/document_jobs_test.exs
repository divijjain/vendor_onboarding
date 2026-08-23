defmodule DocumentComplianceEngine.DocumentJobsTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.DocumentJobs

  test "get_document_job/1 delegates to the repository" do
    owner = user_fixture()

    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "ctx-1",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    assert {:ok, found} = DocumentJobs.get_document_job(document_job.id)
    assert found.id == document_job.id
    assert DocumentJobs.get_document_job(-1) == {:error, :not_found}
  end

  test "list_document_jobs/2 delegates to the repository" do
    owner = user_fixture()

    {:ok, _document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "ctx-2",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    assert [_ | _] = DocumentJobs.list_document_jobs(owner.organization_id)
  end
end
