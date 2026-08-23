defmodule DocumentComplianceEngine.DocumentJobs.RepositoryTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.DocumentJobs.Repository

  setup do
    %{owner: user_fixture()}
  end

  defp valid_attrs(owner, overrides \\ %{}) do
    Map.merge(
      %{
        idempotency_key: "abc123",
        document_paths: %{
          "contract" => "priv/uploads/contract.pdf",
          "w9" => "priv/uploads/w9.pdf"
        },
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      },
      overrides
    )
  end

  describe "insert/1" do
    test "creates a row with status :received on the happy path", %{owner: owner} do
      assert {:ok, document_job} = Repository.insert(valid_attrs(owner))
      assert document_job.status == :received
      assert document_job.idempotency_key == "abc123"
      assert document_job.owner_user_id == owner.id
      assert document_job.organization_id == owner.organization_id
    end

    test "rejects a duplicate idempotency_key", %{owner: owner} do
      assert {:ok, _} = Repository.insert(valid_attrs(owner))
      assert {:error, changeset} = Repository.insert(valid_attrs(owner))
      assert "has already been taken" in errors_on(changeset).idempotency_key
    end

    test "requires idempotency_key, document_paths, and owner_user_id" do
      assert {:error, changeset} = Repository.insert(%{})

      assert %{idempotency_key: ["can't be blank"], owner_user_id: ["can't be blank"]} =
               errors_on(changeset)
    end
  end

  describe "get_by_idempotency_key/1" do
    test "finds an existing row", %{owner: owner} do
      {:ok, document_job} = Repository.insert(valid_attrs(owner))
      assert %{id: id} = Repository.get_by_idempotency_key("abc123")
      assert id == document_job.id
    end

    test "returns nil when no row matches" do
      assert Repository.get_by_idempotency_key("missing") == nil
    end
  end

  describe "get/1 (unscoped)" do
    test "returns {:ok, document_job} for an existing id", %{owner: owner} do
      {:ok, document_job} = Repository.insert(valid_attrs(owner))
      assert {:ok, found} = Repository.get(document_job.id)
      assert found.id == document_job.id
    end

    test "returns {:error, :not_found} for a missing id" do
      assert Repository.get(-1) == {:error, :not_found}
    end
  end

  describe "get/2 (organization-scoped)" do
    test "returns {:ok, document_job} when the organization matches", %{owner: owner} do
      {:ok, document_job} = Repository.insert(valid_attrs(owner))
      assert {:ok, found} = Repository.get(document_job.id, owner.organization_id)
      assert found.id == document_job.id
    end

    test "returns {:ok, document_job} for a different user in the same organization", %{
      owner: owner
    } do
      teammate = user_fixture(%{organization_id: owner.organization_id})
      {:ok, document_job} = Repository.insert(valid_attrs(owner))

      assert {:ok, found} = Repository.get(document_job.id, teammate.organization_id)
      assert found.id == document_job.id
    end

    test "returns {:error, :not_found} when the organization doesn't match — same as a missing id",
         %{owner: owner} do
      {:ok, document_job} = Repository.insert(valid_attrs(owner))
      other_owner = user_fixture()

      assert Repository.get(document_job.id, other_owner.organization_id) == {:error, :not_found}
    end
  end

  describe "update_status/2" do
    test "updates the status", %{owner: owner} do
      {:ok, document_job} = Repository.insert(valid_attrs(owner))

      assert {:ok, updated} = Repository.update_status(document_job.id, :processing)
      assert updated.status == :processing
    end

    test "returns {:error, :not_found} for a missing id" do
      assert Repository.update_status(-1, :processing) == {:error, :not_found}
    end
  end

  describe "list/2" do
    test "filters by status, scoped to the organization", %{owner: owner} do
      {:ok, received} = Repository.insert(valid_attrs(owner))

      {:ok, approved} =
        Repository.insert(valid_attrs(owner, %{idempotency_key: "other-key"}))

      {:ok, approved} = Repository.update_status(approved.id, :approved)

      assert [found] = Repository.list(owner.organization_id, status: :approved)
      assert found.id == approved.id
      refute found.id == received.id
    end

    test "never returns another organization's document_jobs", %{owner: owner} do
      {:ok, _mine} = Repository.insert(valid_attrs(owner))

      other_owner = user_fixture()
      {:ok, _theirs} = Repository.insert(valid_attrs(other_owner, %{idempotency_key: "theirs"}))

      assert [found] = Repository.list(owner.organization_id)
      assert found.organization_id == owner.organization_id
    end

    test "returns document_jobs for every member of the same organization", %{owner: owner} do
      teammate = user_fixture(%{organization_id: owner.organization_id})

      {:ok, mine} = Repository.insert(valid_attrs(owner))

      {:ok, theirs} =
        Repository.insert(
          valid_attrs(teammate, %{
            idempotency_key: "teammate-key",
            organization_id: owner.organization_id
          })
        )

      found_ids = Repository.list(owner.organization_id) |> Enum.map(& &1.id) |> Enum.sort()
      assert found_ids == Enum.sort([mine.id, theirs.id])
    end
  end
end
