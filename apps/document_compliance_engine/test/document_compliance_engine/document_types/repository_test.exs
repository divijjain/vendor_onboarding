defmodule DocumentComplianceEngine.DocumentTypes.RepositoryTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.DocumentTypes.Repository

  @valid_attrs %{slug: "purchase_order", name: "Purchase Order"}

  describe "insert/1" do
    test "creates a row on the happy path" do
      assert {:ok, document_type} = Repository.insert(@valid_attrs)
      assert document_type.slug == "purchase_order"
      assert document_type.name == "Purchase Order"
      assert document_type.extraction_schema == %{}
      assert document_type.validation_rules == []
    end

    test "rejects a duplicate slug" do
      assert {:ok, _} = Repository.insert(@valid_attrs)
      assert {:error, changeset} = Repository.insert(@valid_attrs)
      assert "has already been taken" in errors_on(changeset).slug
    end

    test "requires slug and name" do
      assert {:error, changeset} = Repository.insert(%{})
      assert %{slug: ["can't be blank"], name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get_by_slug/1" do
    test "finds an existing row" do
      {:ok, document_type} = Repository.insert(@valid_attrs)
      assert %{id: id} = Repository.get_by_slug("purchase_order")
      assert id == document_type.id
    end

    test "returns nil when no row matches" do
      assert Repository.get_by_slug("missing") == nil
    end
  end

  describe "list/0" do
    test "includes the migration-seeded vendor_contract_w9 type plus any created since" do
      {:ok, _} = Repository.insert(@valid_attrs)

      slugs = Repository.list() |> Enum.map(& &1.slug)
      assert "vendor_contract_w9" in slugs
      assert "purchase_order" in slugs
    end
  end
end
