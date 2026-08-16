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
end
