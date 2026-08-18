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

    assert {:ok, extracted, metadata} =
             Extraction.extract_all(%{"contract" => "c", "w9" => "w"}, @extraction_schema)

    assert extracted["contract"] == %{company_name: "value", payment_terms: "value"}
    assert extracted["w9"] == %{company_name: "value", tax_id: "value"}

    # The fake doesn't return metadata, so extraction reports none — a
    # fake opting in to it is covered separately below.
    assert metadata == %{"contract" => %{}, "w9" => %{}}

    assert_received {:called, "contract", %{company_name: :string, payment_terms: :string}}
    assert_received {:called, "w9", %{company_name: :string, tax_id: :string}}
  end

  test "a fake may opt in to returning confidence + source_quote metadata" do
    stub_defaults(
      extract: fn "contract", _schema, _text ->
        {:ok, %{company_name: "Acme Corp", payment_terms: "Net 30"},
         %{company_name: %{confidence: 0.55, source_quote: "Acme Corp"}}}
      end
    )

    assert {:ok, extracted, metadata} =
             Extraction.extract_all(%{"contract" => "c"}, %{
               "contract" => %{"company_name" => "string", "payment_terms" => "string"}
             })

    assert extracted["contract"].company_name == "Acme Corp"
    assert metadata["contract"].company_name == %{confidence: 0.55, source_quote: "Acme Corp"}
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

  describe "extract_all/3 shape gate" do
    test "skips the LLM entirely and returns nil fields for a role that fails its shape gate" do
      test_pid = self()

      stub_defaults(extract: fn role, _schema, _text -> send(test_pid, {:called, role}) end)

      shape_signals = %{
        "invoice" => %{"keywords" => ["invoice", "bill to"], "min_matches" => 2}
      }

      schema = %{
        "invoice" => %{"vendor_name" => "string", "amount" => "string"}
      }

      assert {:ok, extracted, metadata} =
               Extraction.extract_all(
                 %{"invoice" => "I am writing to express my enthusiasm for this position."},
                 schema,
                 shape_signals
               )

      assert extracted["invoice"] == %{vendor_name: nil, amount: nil}

      assert metadata["invoice"] == %{
               vendor_name: %{confidence: nil, source_quote: nil},
               amount: %{confidence: nil, source_quote: nil}
             }

      refute_received {:called, "invoice"}
    end

    test "runs extraction normally when the shape gate passes" do
      stub_defaults(
        extract: fn "invoice", _schema, _text -> {:ok, %{vendor_name: "Acme Corp"}} end
      )

      shape_signals = %{
        "invoice" => %{"keywords" => ["invoice", "vendor"], "min_matches" => 1}
      }

      assert {:ok, extracted, _metadata} =
               Extraction.extract_all(
                 %{"invoice" => "INVOICE\nVendor: Acme Corp"},
                 %{"invoice" => %{"vendor_name" => "string"}},
                 shape_signals
               )

      assert extracted["invoice"] == %{vendor_name: "Acme Corp"}
    end

    test "a role with no shape_signals entry is always extracted" do
      stub_defaults(extract: fn "contract", _schema, _text -> {:ok, %{company_name: "Acme"}} end)

      assert {:ok, extracted, _metadata} =
               Extraction.extract_all(
                 %{"contract" => "anything at all"},
                 %{"contract" => %{"company_name" => "string"}},
                 %{}
               )

      assert extracted["contract"] == %{company_name: "Acme"}
    end
  end

  describe "shape_matches?/2" do
    test "passes when unconfigured (nil or empty map)" do
      assert Extraction.shape_matches?("anything", nil)
      assert Extraction.shape_matches?("anything", %{})
    end

    test "passes when at least min_matches keywords are present" do
      shape = %{"keywords" => ["invoice", "vendor", "amount"], "min_matches" => 2}
      assert Extraction.shape_matches?("This INVOICE lists the Vendor name.", shape)
    end

    test "fails when fewer than min_matches keywords are present" do
      shape = %{"keywords" => ["invoice", "bill to", "amount due"], "min_matches" => 2}
      refute Extraction.shape_matches?("Just a résumé mentioning a Vendor in passing.", shape)
    end

    test "is case- and whitespace-insensitive" do
      shape = %{"keywords" => ["bill   to"], "min_matches" => 1}
      assert Extraction.shape_matches?("Please see BILL TO section below.", shape)
    end
  end

  describe "denote_missing/1" do
    test "converts the NOT_PRESENT sentinel to nil" do
      assert Extraction.denote_missing(%{vendor_name: "Acme", invoice_number: "NOT_PRESENT"}) ==
               %{vendor_name: "Acme", invoice_number: nil}
    end

    test "leaves other values untouched" do
      fields = %{a: "real value", b: ""}
      assert Extraction.denote_missing(fields) == fields
    end
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

      assert {:ok, fields, metadata} = Extraction.extract("w9", @field_types, text)

      # tax_id came from the regex match, verbatim — not the fake's canned value.
      assert fields.tax_id == "12-3456789"
      assert fields.company_name == "fake-company_name"

      # A regex-resolved field is deterministically grounded — full
      # confidence, and the source_quote is the matched text itself.
      assert metadata.tax_id == %{confidence: 1.0, source_quote: "12-3456789"}

      # The LLM (fake) was only ever asked for company_name.
      assert_received {:called, "w9", response_model}
      refute Map.has_key?(response_model, :tax_id)
    end

    test "skips the LLM call entirely when regex resolves every field in the role" do
      test_pid = self()
      text = "EIN: 12-3456789"

      stub_defaults(extract: fn role, _schema, _text -> send(test_pid, {:called, role}) end)

      assert {:ok, %{tax_id: "12-3456789"},
              %{tax_id: %{confidence: 1.0, source_quote: "12-3456789"}}} =
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

      assert {:ok, fields, _metadata} =
               Extraction.extract("w9", @field_types, "no ein in this text")

      assert fields.tax_id == "fake-tax_id"
      assert_received {:called, "w9", %{company_name: :string, tax_id: :string}}
    end
  end
end
