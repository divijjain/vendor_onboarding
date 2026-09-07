defmodule DocumentComplianceEngine.Agent.Evals.DeterministicTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.Evals.Deterministic

  @source "2. Taxpayer Identification Number (EIN): 12-3456789\n"

  test "passes when the extracted tax id appears verbatim in the source" do
    assert Deterministic.tax_id_verbatim?("12-3456789", @source)
  end

  test "tolerates surrounding whitespace on the extracted value" do
    assert Deterministic.tax_id_verbatim?("  12-3456789  ", @source)
  end

  test "fails on a hallucinated tax id that is not in the source" do
    refute Deterministic.tax_id_verbatim?("99-9999999", @source)
  end

  test "fails on an empty or absent extraction" do
    refute Deterministic.tax_id_verbatim?("", @source)
    refute Deterministic.tax_id_verbatim?("   ", @source)
    refute Deterministic.tax_id_verbatim?(nil, @source)
  end

  describe "expected_fields_ok?/2" do
    @extracted %{"purchase_order" => %{order_date: "2026-07-02", delivery_date: "2026-08-20"}}

    test "is nil when a fixture states no expected values" do
      # Most fixtures state none; nil keeps them out of the reported
      # denominator rather than counting as passes.
      assert Deterministic.expected_fields_ok?(@extracted, nil) == nil
      assert Deterministic.expected_fields_ok?(@extracted, %{}) == nil
    end

    test "passes when every stated field matches exactly" do
      expected = %{"purchase_order" => %{order_date: "2026-07-02", delivery_date: "2026-08-20"}}
      assert Deterministic.expected_fields_ok?(@extracted, expected)
    end

    test "catches two grounded values swapped between fields" do
      # The case decision accuracy and grounding both miss: both values are
      # verbatim present in the document, just against the wrong fields.
      swapped = %{"purchase_order" => %{order_date: "2026-08-20", delivery_date: "2026-07-02"}}

      refute Deterministic.expected_fields_ok?(@extracted, swapped)

      assert Enum.sort(Deterministic.expected_field_mismatches(@extracted, swapped)) == [
               "purchase_order.delivery_date: expected \"2026-07-02\", got \"2026-08-20\"",
               "purchase_order.order_date: expected \"2026-08-20\", got \"2026-07-02\""
             ]
    end

    test "fails when a stated field is missing entirely" do
      expected = %{"purchase_order" => %{po_number: "PO-4503"}}

      refute Deterministic.expected_fields_ok?(@extracted, expected)
      assert [mismatch] = Deterministic.expected_field_mismatches(@extracted, expected)
      assert mismatch =~ "got nil"
    end

    test "fails when a stated role is missing entirely" do
      refute Deterministic.expected_fields_ok?(@extracted, %{"receipt" => %{total: "10.00"}})
    end
  end
end
