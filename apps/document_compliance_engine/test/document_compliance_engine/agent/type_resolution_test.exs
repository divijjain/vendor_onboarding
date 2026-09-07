defmodule DocumentComplianceEngine.Agent.TypeResolutionTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.TypeResolution

  defp invoice_candidate do
    %{
      "slug" => "invoice",
      "name" => "Vendor invoice",
      "description" => "A commercial invoice.",
      "extraction_schema" => %{"invoice" => %{"amount" => %{"type" => "monetary_amount"}}},
      "validation_rules" => [%{"type" => "format", "validator" => "number"}],
      "shape_signals" => %{"invoice" => %{"keywords" => ["invoice"], "min_matches" => 1}}
    }
  end

  defp bundle_candidate do
    %{
      "slug" => "vendor_contract_w9",
      "name" => "Vendor contract + W-9",
      "description" => "A contract and a W-9.",
      "extraction_schema" => %{
        "contract" => %{"company_name" => %{"type" => "string"}},
        "w9" => %{"tax_id" => %{"type" => "string"}}
      },
      "validation_rules" => [],
      "shape_signals" => %{}
    }
  end

  defp classification(overrides) do
    Map.merge(
      %{
        slug: "invoice",
        confidence: 1.0,
        source: :shape_signals,
        reasoning: nil,
        confident?: true
      },
      overrides
    )
  end

  describe "a confident classification" do
    test "hands the chosen type's config to the rest of the pipeline, with no findings" do
      resolved =
        TypeResolution.resolve(
          classification(%{}),
          [invoice_candidate()],
          %{"invoice" => "INVOICE"}
        )

      assert resolved.document_type_slug == "invoice"
      assert resolved.extraction_schema == invoice_candidate()["extraction_schema"]
      assert resolved.validation_rules == invoice_candidate()["validation_rules"]
      assert resolved.shape_signals == invoice_candidate()["shape_signals"]
      assert resolved.checks == []
    end

    test "re-keys a single upload onto a single-role type's role, whatever it was called" do
      resolved =
        TypeResolution.resolve(
          classification(%{}),
          [invoice_candidate()],
          %{"some-upload.pdf" => "INVOICE"}
        )

      assert resolved.documents == %{"invoice" => "INVOICE"}
      assert resolved.checks == []
    end

    test "passes matching role names through untouched" do
      documents = %{"contract" => "an agreement", "w9" => "a w-9"}

      resolved =
        TypeResolution.resolve(
          classification(%{slug: "vendor_contract_w9"}),
          [bundle_candidate()],
          documents
        )

      assert resolved.documents == documents
      assert resolved.checks == []
    end

    test "refuses to guess which upload is which role, and extracts nothing" do
      resolved =
        TypeResolution.resolve(
          classification(%{slug: "vendor_contract_w9"}),
          [bundle_candidate()],
          %{"a.pdf" => "one", "b.pdf" => "two"}
        )

      # Pairing these up by position would produce a confidently wrong
      # extraction; an empty schema plus a finding is the honest answer.
      assert resolved.extraction_schema == %{}
      assert [check] = resolved.checks
      assert check.rule["type"] == "document_roles"
      assert check.detail =~ "could not be matched to vendor_contract_w9's roles"
      refute check.passed
    end
  end

  describe "an unconfident classification" do
    test "still extracts under the proposed type, and says so" do
      resolved =
        TypeResolution.resolve(
          classification(%{
            confidence: 0.4,
            confident?: false,
            source: :llm,
            reasoning: "could be a receipt"
          }),
          [invoice_candidate()],
          %{"invoice" => "INVOICE"}
        )

      # The evidence the reviewer needs to answer the question they're asked.
      assert resolved.document_type_slug == "invoice"
      assert resolved.extraction_schema == invoice_candidate()["extraction_schema"]

      assert [check] = resolved.checks
      assert check.rule["type"] == "classification"
      assert check.rule["confidence"] == 0.4
      assert check.detail =~ "Classified as invoice with low confidence (0.40"
      assert check.detail =~ "could be a receipt"
    end

    test "keeps a role-mapping finding alongside the low-confidence one" do
      resolved =
        TypeResolution.resolve(
          classification(%{slug: "vendor_contract_w9", confidence: 0.3, confident?: false}),
          [bundle_candidate()],
          %{"a.pdf" => "one", "b.pdf" => "two"}
        )

      assert [classification_check, roles_check] = resolved.checks
      assert classification_check.rule["type"] == "classification"
      assert roles_check.rule["type"] == "document_roles"
    end
  end

  describe "no classifiable type" do
    test "extracts nothing and reports why, without inventing a type" do
      resolved =
        TypeResolution.resolve(
          classification(%{
            slug: nil,
            confidence: 0.0,
            source: :none,
            confident?: false,
            reasoning: "This is a cover letter"
          }),
          [invoice_candidate()],
          %{"document" => "Dear Hiring Manager"}
        )

      assert resolved.document_type_slug == nil
      assert resolved.extraction_schema == %{}
      assert resolved.validation_rules == []
      assert resolved.documents == %{"document" => "Dear Hiring Manager"}

      assert [check] = resolved.checks
      assert check.detail =~ "Could not determine what kind of document this is"
      assert check.detail =~ "This is a cover letter"
    end

    test "a slug that isn't among the candidates is treated the same way" do
      resolved =
        TypeResolution.resolve(
          classification(%{slug: "receipt"}),
          [invoice_candidate()],
          %{"document" => "RECEIPT"}
        )

      assert resolved.document_type_slug == nil
      assert resolved.extraction_schema == %{}
    end
  end
end
