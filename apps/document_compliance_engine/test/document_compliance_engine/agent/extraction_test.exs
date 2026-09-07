defmodule DocumentComplianceEngine.Agent.ExtractionTest do
  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.Extraction

  @extraction_schema %{
    "contract" => %{
      "company_name" => %{"type" => "string"},
      "payment_terms" => %{"type" => "string"}
    },
    "w9" => %{"company_name" => %{"type" => "string"}, "tax_id" => %{"type" => "string"}}
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
               "contract" => %{
                 "company_name" => %{"type" => "string"},
                 "payment_terms" => %{"type" => "string"}
               }
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
        "invoice" => %{"vendor_name" => %{"type" => "string"}, "amount" => %{"type" => "string"}}
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
                 %{"invoice" => %{"vendor_name" => %{"type" => "string"}}},
                 shape_signals
               )

      assert extracted["invoice"] == %{vendor_name: "Acme Corp"}
    end

    test "a role with no shape_signals entry is always extracted" do
      stub_defaults(extract: fn "contract", _schema, _text -> {:ok, %{company_name: "Acme"}} end)

      assert {:ok, extracted, _metadata} =
               Extraction.extract_all(
                 %{"contract" => "anything at all"},
                 %{"contract" => %{"company_name" => %{"type" => "string"}}},
                 %{}
               )

      assert extracted["contract"] == %{company_name: "Acme"}
    end
  end

  describe "declared field types" do
    @typed_schema %{
      "invoice" => %{
        "vendor_name" => %{"type" => "string"},
        "amount" => %{"type" => "number"},
        "due_date" => %{"type" => "date"}
      }
    }

    test "a declared type never changes the wire type asked of the model" do
      test_pid = self()

      stub_defaults(
        extract: fn role, response_model, _text ->
          send(test_pid, {:called, role, response_model})
          {:ok, Map.new(response_model, fn {field, _type} -> {field, "value"} end)}
        end
      )

      assert {:ok, extracted, _metadata} =
               Extraction.extract_all(%{"invoice" => "INVOICE"}, @typed_schema)

      # Every field is still requested as a string and comes back verbatim —
      # a coerced number/date would stop matching the source document and be
      # reported as a possible hallucination by Checks. See the moduledoc.
      assert_received {:called, "invoice",
                       %{vendor_name: :string, amount: :string, due_date: :string}}

      assert extracted["invoice"] == %{vendor_name: "value", amount: "value", due_date: "value"}
    end

    test "an unknown field type fails the run before any LLM call is spent" do
      test_pid = self()

      stub_defaults(extract: fn role, _schema, _text -> send(test_pid, {:called, role}) end)

      schema = %{
        "invoice" => %{"vendor_name" => %{"type" => "string"}, "amount" => %{"type" => "monies"}}
      }

      assert {:error, {:unknown_field_type, "invoice", "amount", "monies"}} =
               Extraction.extract_all(%{"invoice" => "INVOICE"}, schema)

      refute_received {:called, "invoice"}
    end

    test "an unknown type is caught even in a role the shape gate would skip" do
      shape_signals = %{"invoice" => %{"keywords" => ["invoice"], "min_matches" => 1}}
      schema = %{"invoice" => %{"amount" => %{"type" => "monies"}}}

      stub_defaults()

      assert {:error, {:unknown_field_type, "invoice", "amount", "monies"}} =
               Extraction.extract_all(
                 %{"invoice" => "not an invoice at all"},
                 schema,
                 shape_signals
               )
    end
  end

  describe "prompt/2" do
    test "names each field's declared type and forbids reformatting to match it" do
      prompt =
        Extraction.prompt("invoice", %{
          "amount" => %{"type" => "number"},
          "due_date" => %{"type" => "date"}
        })

      assert prompt =~ "- amount: Written as a number."
      assert prompt =~ "- due_date: Written as a date."
      assert prompt =~ "copy that value exactly as the document writes it"
    end

    test "carries each field's semantic description into the prompt" do
      prompt =
        Extraction.prompt("invoice", %{
          "amount" => %{
            "type" => "monetary_amount",
            "description" => "The total payable, not a line item."
          },
          "vendor_name" => %{"description" => "The business being paid, not the buyer."}
        })

      # Type first, then meaning — and a field may carry a description
      # with no type worth naming, which is the `vendor_name` case.
      assert prompt =~
               "- amount: Written as a monetary amount, with any currency symbol the " <>
                 "document writes. The total payable, not a line item."

      assert prompt =~ "- vendor_name: The business being paid, not the buyer."
    end

    test "an unannotated field is listed bare, with no empty annotation left dangling" do
      prompt =
        Extraction.prompt("w9", %{
          "company_name" => %{"type" => "string"},
          "tax_id" => %{"type" => "string"}
        })

      assert prompt =~ "- company_name\n"
      assert prompt =~ "- tax_id\n"
      # Nothing said about types, because nothing was declared worth saying.
      refute prompt =~ "Written as"
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

  describe "recover_blank_companions/1" do
    # Reproduces the real changeset from a live run: the primary field
    # correctly used the NOT_PRESENT sentinel, but the model left its
    # companion source_quote blank instead — see CONTEXT.md's dated entry.
    test "recovers a single blank source_quote companion with the sentinel" do
      changeset = %Ecto.Changeset{
        changes: %{
          company_name: "NOT_PRESENT",
          tax_id: "N/A",
          company_name_confidence: 0.0,
          tax_id_confidence: 1.0,
          tax_id_source_quote: "Taxpayer Identification Number (EIN): N/A"
        },
        errors: [company_name_source_quote: {"can't be blank", [validation: :required]}]
      }

      assert {:ok, recovered} = Extraction.recover_blank_companions(changeset)
      assert recovered.company_name_source_quote == "NOT_PRESENT"
      assert recovered.company_name == "NOT_PRESENT"
      assert recovered.tax_id_source_quote == "Taxpayer Identification Number (EIN): N/A"
    end

    test "recovers a blank confidence companion with 0.0" do
      changeset = %Ecto.Changeset{
        changes: %{vendor_name: "NOT_PRESENT", vendor_name_source_quote: "NOT_PRESENT"},
        errors: [vendor_name_confidence: {"can't be blank", [validation: :required]}]
      }

      assert {:ok, recovered} = Extraction.recover_blank_companions(changeset)
      assert recovered.vendor_name_confidence == 0.0
    end

    test "recovers multiple blank companions at once" do
      # The real case that hit invoice's scanned_malformed fixture: three
      # companion fields blank in the same completion.
      changeset = %Ecto.Changeset{
        changes: %{
          vendor_name: "Fairview Trading Co.",
          vendor_name_source_quote: "Vendor: Fairview Trading Co.",
          vendor_name_confidence: 1.0,
          amount: "NOT_PRESENT",
          due_date: "NOT_PRESENT",
          invoice_number: "NOT_PRESENT"
        },
        errors: [
          amount_source_quote: {"can't be blank", [validation: :required]},
          due_date_source_quote: {"can't be blank", [validation: :required]},
          invoice_number_source_quote: {"can't be blank", [validation: :required]}
        ]
      }

      assert {:ok, recovered} = Extraction.recover_blank_companions(changeset)
      assert recovered.amount_source_quote == "NOT_PRESENT"
      assert recovered.due_date_source_quote == "NOT_PRESENT"
      assert recovered.invoice_number_source_quote == "NOT_PRESENT"
      assert recovered.vendor_name == "Fairview Trading Co."
    end

    test "does not recover when a primary field also failed validation" do
      # A real missing value is a different, more serious problem than a
      # metadata companion quirk — must not be silently papered over.
      changeset = %Ecto.Changeset{
        changes: %{company_name_confidence: 0.0, company_name_source_quote: ""},
        errors: [
          company_name: {"can't be blank", [validation: :required]},
          company_name_source_quote: {"can't be blank", [validation: :required]}
        ]
      }

      assert Extraction.recover_blank_companions(changeset) == :error
    end

    test "does not recover when there are no errors at all" do
      changeset = %Ecto.Changeset{changes: %{}, errors: []}
      assert Extraction.recover_blank_companions(changeset) == :error
    end
  end

  describe "maybe_regex_extract/2" do
    @field_types %{"company_name" => %{"type" => "string"}, "tax_id" => %{"type" => "string"}}

    test "resolves tax_id and removes it from the remaining fields when it appears exactly once" do
      text = "FORM W-9\n1. Name of entity: Acme Corp\n2. EIN: 12-3456789\n"

      assert {:resolved, :tax_id, "12-3456789", remaining} =
               Extraction.maybe_regex_extract(@field_types, text)

      assert remaining == %{"company_name" => %{"type" => "string"}}
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
               Extraction.maybe_regex_extract(
                 %{"company_name" => %{"type" => "string"}},
                 "EIN: 12-3456789"
               )
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
               Extraction.extract("w9", %{"tax_id" => %{"type" => "string"}}, text)

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
