defmodule DocumentComplianceEngine.Agent.ExtractionTest do
  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.Extraction

  @extraction_schema %{
    "contract" => %{"company_name" => "string", "payment_terms" => "string"},
    "w9" => %{"company_name" => "string", "tax_id" => "string"}
  }

  test "extracts every role and converts each field schema to an atom-keyed response model" do
    test_pid = self()

    stub_defaults(
      extract: fn role, response_model, _text ->
        send(test_pid, {:called, role, response_model})
        {:ok, Map.new(response_model, fn {field, _type} -> {field, "value"} end)}
      end
    )

    assert {:ok, extracted} =
             Extraction.extract_all(%{"contract" => "c", "w9" => "w"}, @extraction_schema)

    assert extracted["contract"] == %{company_name: "value", payment_terms: "value"}
    assert extracted["w9"] == %{company_name: "value", tax_id: "value"}

    assert_received {:called, "contract", %{company_name: :string, payment_terms: :string}}
    assert_received {:called, "w9", %{company_name: :string, tax_id: :string}}
  end

  test "fails the whole extraction when a role's document text is missing" do
    stub_defaults()

    assert {:error, {:missing_document, "w9"}} =
             Extraction.extract_all(%{"contract" => "c"}, @extraction_schema)
  end

  test "fails the whole extraction when one role's LLM call errors" do
    stub_defaults(
      extract: fn
        "contract", _schema, _text -> {:error, :boom}
        "w9", _schema, _text -> {:ok, %{company_name: "Acme", tax_id: "1"}}
      end
    )

    assert {:error, :boom} =
             Extraction.extract_all(%{"contract" => "c", "w9" => "w"}, @extraction_schema)
  end

  describe "maybe_regex_extract/2" do
    @field_types %{"company_name" => "string", "tax_id" => "string"}

    test "resolves tax_id and removes it from the remaining fields when it appears exactly once" do
      text = "FORM W-9\n1. Name of entity: Acme Corp\n2. EIN: 12-3456789\n"

      assert {:resolved, :tax_id, "12-3456789", remaining} =
               Extraction.maybe_regex_extract(@field_types, text)

      assert remaining == %{"company_name" => "string"}
    end

    test "is unresolved when the pattern doesn't appear" do
      assert :unresolved = Extraction.maybe_regex_extract(@field_types, "no ein here")
    end

    test "is unresolved (never guesses) when the pattern appears more than once" do
      text = "EIN: 12-3456789, also possibly 98-7654321"
      assert :unresolved = Extraction.maybe_regex_extract(@field_types, text)
    end

    test "is unresolved when the schema has no tax_id field at all" do
      assert :unresolved =
               Extraction.maybe_regex_extract(%{"company_name" => "string"}, "EIN: 12-3456789")
    end
  end

  describe "extract/3 regex-first behavior for tax_id" do
    test "resolves tax_id via regex and only asks the LLM for the remaining fields" do
      test_pid = self()
      text = "FORM W-9\n1. Name of entity: Acme Corp\n2. EIN: 12-3456789\n"

      stub_defaults(
        extract: fn role, response_model, _text ->
          send(test_pid, {:called, role, response_model})
          {:ok, Map.new(response_model, fn {field, _type} -> {field, "fake-#{field}"} end)}
        end
      )

      assert {:ok, fields} = Extraction.extract("w9", @field_types, text)

      # tax_id came from the regex match, verbatim — not the fake's canned value.
      assert fields.tax_id == "12-3456789"
      assert fields.company_name == "fake-company_name"

      # The LLM (fake) was only ever asked for company_name.
      assert_received {:called, "w9", response_model}
      refute Map.has_key?(response_model, :tax_id)
    end

    test "skips the LLM call entirely when regex resolves every field in the role" do
      test_pid = self()
      text = "EIN: 12-3456789"

      stub_defaults(extract: fn role, _schema, _text -> send(test_pid, {:called, role}) end)

      assert {:ok, %{tax_id: "12-3456789"}} =
               Extraction.extract("w9", %{"tax_id" => "string"}, text)

      refute_received {:called, "w9"}
    end

    test "falls through to the normal full extraction when the EIN pattern isn't present" do
      test_pid = self()

      stub_defaults(
        extract: fn role, response_model, _text ->
          send(test_pid, {:called, role, response_model})
          {:ok, Map.new(response_model, fn {field, _type} -> {field, "fake-#{field}"} end)}
        end
      )

      assert {:ok, fields} = Extraction.extract("w9", @field_types, "no ein in this text")

      assert fields.tax_id == "fake-tax_id"
      assert_received {:called, "w9", %{company_name: :string, tax_id: :string}}
    end
  end
end
