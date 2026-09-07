defmodule DocumentComplianceEngine.Agent.FieldTypesTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.FieldTypes
  alias DocumentComplianceEngine.Agent.FormatValidators

  describe "known/0" do
    test "includes the untyped default and the types the seeded document types use" do
      assert "string" in FieldTypes.known()
      assert "number" in FieldTypes.known()
      assert "date" in FieldTypes.known()
    end

    test "every type other than string is also a FormatValidators validator name" do
      # The invariant that keeps the two vocabularies from drifting — see
      # FieldTypes' moduledoc. Enforced at compile time too; asserted here
      # so the reason is visible in the test suite as well.
      for type <- FieldTypes.known(), type != "string" do
        assert type in FormatValidators.known()
      end
    end

    test "identifier schemes are deliberately not types" do
      # An EIN/IBAN/VIN is a claim about what a value is, not how it is
      # written — those stay "string" plus a format/regex/mcp_tool rule.
      refute "iban" in FieldTypes.known()
      refute "vin" in FieldTypes.known()
      refute "vat_id" in FieldTypes.known()
      refute "credit_card" in FieldTypes.known()
    end
  end

  describe "describe/1" do
    test "returns prompt phrasing for a real type" do
      assert FieldTypes.describe("number") == "a number"
      assert FieldTypes.describe("date") == "a date"
    end

    test "returns nil for string, so an untyped field gets no hint at all" do
      assert FieldTypes.describe("string") == nil
    end

    test "returns nil rather than inventing phrasing for an unknown or non-binary type" do
      assert FieldTypes.describe("monies") == nil
      assert FieldTypes.describe(nil) == nil
      assert FieldTypes.describe(:number) == nil
    end
  end
end
