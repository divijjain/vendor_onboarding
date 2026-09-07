defmodule DocumentComplianceEngine.Agent.ExtractionSchemaTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.ExtractionSchema

  @schema %{
    "invoice" => %{
      "vendor_name" => %{"type" => "string", "description" => "The business being paid."},
      "amount" => %{"type" => "monetary_amount"},
      "due_date" => %{"type" => "date"}
    }
  }

  describe "reading a schema" do
    test "roles/1 and fields/2 read the structure" do
      assert ExtractionSchema.roles(@schema) == ["invoice"]

      assert Map.keys(ExtractionSchema.fields(@schema, "invoice")) |> Enum.sort() ==
               ["amount", "due_date", "vendor_name"]
    end

    test "fields/2 is empty rather than nil for a role the schema doesn't describe" do
      assert ExtractionSchema.fields(@schema, "receipt") == %{}
    end

    test "type/1 and description/1 read one spec" do
      spec = @schema["invoice"]["vendor_name"]

      assert ExtractionSchema.type(spec) == "string"
      assert ExtractionSchema.description(spec) == "The business being paid."
    end

    test "description/1 is nil when absent or blank, never an empty string" do
      assert ExtractionSchema.description(%{"type" => "date"}) == nil
      assert ExtractionSchema.description(%{"type" => "date", "description" => ""}) == nil
    end

    test "type/1 is nil for a malformed spec rather than crashing" do
      # validate/1 is what reports these loudly; readers stay total.
      assert ExtractionSchema.type("monetary_amount") == nil
      assert ExtractionSchema.type(%{"description" => "no type here"}) == nil
      assert ExtractionSchema.type(nil) == nil
    end
  end

  describe "validate/1" do
    test "accepts a well-formed schema, with or without descriptions" do
      assert :ok = ExtractionSchema.validate(@schema)
      assert :ok = ExtractionSchema.validate(%{"w9" => %{"tax_id" => %{"type" => "string"}}})
      assert :ok = ExtractionSchema.validate(%{})
    end

    test "reports an unknown type with the role, field and offending value" do
      schema = %{"invoice" => %{"amount" => %{"type" => "monies"}}}

      assert {:error, {:unknown_field_type, "invoice", "amount", "monies"}} =
               ExtractionSchema.validate(schema)
    end

    test "rejects the pre-description bare-string form as an unmigrated row" do
      # Deliberately not accepted for compatibility — see the moduledoc.
      assert {:error, {:invalid_field_spec, "invoice", "amount"}} =
               ExtractionSchema.validate(%{"invoice" => %{"amount" => "monetary_amount"}})
    end

    test "rejects a spec that carries a description but no type" do
      schema = %{"invoice" => %{"amount" => %{"description" => "the total"}}}

      assert {:error, {:invalid_field_spec, "invoice", "amount"}} =
               ExtractionSchema.validate(schema)
    end

    test "rejects an atom type — the config is JSON, types are strings" do
      assert {:error, {:invalid_field_spec, "invoice", "amount"}} =
               ExtractionSchema.validate(%{"invoice" => %{"amount" => %{"type" => :number}}})
    end
  end
end
