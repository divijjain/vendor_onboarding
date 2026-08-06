defmodule VendorOnboarding.Onboardings.RepositoryTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.Onboardings.Repository

  @valid_attrs %{
    idempotency_key: "abc123",
    document_paths: %{"contract" => "priv/uploads/contract.pdf", "w9" => "priv/uploads/w9.pdf"}
  }

  describe "insert/1" do
    test "creates a row with status :received on the happy path" do
      assert {:ok, onboarding} = Repository.insert(@valid_attrs)
      assert onboarding.status == :received
      assert onboarding.idempotency_key == "abc123"
      assert onboarding.document_paths == @valid_attrs.document_paths
    end

    test "rejects a duplicate idempotency_key" do
      assert {:ok, _} = Repository.insert(@valid_attrs)
      assert {:error, changeset} = Repository.insert(@valid_attrs)
      assert "has already been taken" in errors_on(changeset).idempotency_key
    end

    test "requires idempotency_key and document_paths" do
      assert {:error, changeset} = Repository.insert(%{})
      assert %{idempotency_key: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get_by_idempotency_key/1" do
    test "finds an existing row" do
      {:ok, onboarding} = Repository.insert(@valid_attrs)
      assert %{id: id} = Repository.get_by_idempotency_key("abc123")
      assert id == onboarding.id
    end

    test "returns nil when no row matches" do
      assert Repository.get_by_idempotency_key("missing") == nil
    end
  end

  describe "get/1" do
    test "returns {:ok, onboarding} for an existing id" do
      {:ok, onboarding} = Repository.insert(@valid_attrs)
      assert {:ok, found} = Repository.get(onboarding.id)
      assert found.id == onboarding.id
    end

    test "returns {:error, :not_found} for a missing id" do
      assert Repository.get(-1) == {:error, :not_found}
    end
  end

  describe "update_status/2" do
    test "updates the status" do
      {:ok, onboarding} = Repository.insert(@valid_attrs)

      assert {:ok, updated} = Repository.update_status(onboarding.id, :processing)
      assert updated.status == :processing
    end

    test "returns {:error, :not_found} for a missing id" do
      assert Repository.update_status(-1, :processing) == {:error, :not_found}
    end
  end

  describe "list/1" do
    test "filters by status" do
      {:ok, received} = Repository.insert(@valid_attrs)

      {:ok, approved} =
        Repository.insert(%{
          idempotency_key: "other-key",
          document_paths: @valid_attrs.document_paths
        })

      {:ok, approved} = Repository.update_status(approved.id, :approved)

      assert [found] = Repository.list(status: :approved)
      assert found.id == approved.id
      refute found.id == received.id
    end
  end
end
