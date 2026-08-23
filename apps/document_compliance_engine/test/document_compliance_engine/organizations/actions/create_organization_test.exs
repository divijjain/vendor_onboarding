defmodule DocumentComplianceEngine.Organizations.Actions.CreateOrganizationTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.DocumentJobs
  alias DocumentComplianceEngine.Organizations

  test "creates an organization and joins the creator as its first member" do
    user = user_fixture(%{organization_id: nil})

    assert {:ok, organization} = Organizations.create_organization(user, "Acme Corp")
    assert organization.name == "Acme Corp"

    assert {:ok, updated_user} = Accounts.get_user(user.id)
    assert updated_user.organization_id == organization.id
  end

  test "backfills the creator's previously-orphaned (webhook pre-provisioned) document_jobs" do
    user = user_fixture(%{organization_id: nil})

    {:ok, orphaned} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "backfill-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: user.id,
        organization_id: nil
      })

    assert {:ok, organization} = Organizations.create_organization(user, "Acme Corp")

    assert {:ok, backfilled} = DocumentJobs.get_document_job(orphaned.id)
    assert backfilled.organization_id == organization.id
  end
end
