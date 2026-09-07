defmodule DocumentComplianceEngine.Agent.ChecksTest do
  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.{Checks, ValidationResult}
  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult

  @extracted %{
    "contract" => %{company_name: "Acme Corp"},
    "w9" => %{company_name: "Acme Corp", tax_id: "12-3456789"}
  }

  @documents %{
    "contract" => "This agreement is entered into with Acme Corp.",
    "w9" => "Form W-9. Name of entity: Acme Corp. EIN: 12-3456789."
  }

  @entity_match_rule %{
    "type" => "entity_match",
    "fields" => [
      %{"role" => "contract", "name" => "company_name"},
      %{"role" => "w9", "name" => "company_name"}
    ]
  }

  @tax_id_rule %{
    "type" => "mcp_tool",
    "tool" => "validate_tax_id",
    "field" => %{"role" => "w9", "name" => "tax_id"}
  }

  @sanctions_rule %{
    "type" => "mcp_tool",
    "tool" => "screen_vendor",
    "field" => %{"role" => "contract", "name" => "company_name"}
  }

  test "entity_match rule passes when the two named fields match" do
    stub_defaults()

    assert {:ok, %ValidationResult{checks: [check]}} =
             Checks.validate_all(@extracted, @documents, [@entity_match_rule])

    assert check.passed
    assert check.detail == nil
  end

  test "entity_match rule fails and records a detail on mismatch" do
    # Names deliberately land in the staged pre-filter's ambiguous band
    # (see checks.ex's threshold calibration comment) so the LLM fake below
    # actually gets consulted, rather than the pre-filter short-circuiting
    # before the stub is ever reached.
    ambiguous = %{
      "contract" => %{company_name: "Acme Corp"},
      "w9" => %{company_name: "Acme Corporation", tax_id: "12-3456789"}
    }

    ambiguous_documents = %{
      "contract" => "This agreement is entered into with Acme Corp.",
      "w9" => "Form W-9. Name of entity: Acme Corporation. EIN: 12-3456789."
    }

    stub_defaults(
      entity_match: fn _a, _b ->
        {:ok, %EntityMatchResult{match: false, explanation: "different entities"}}
      end
    )

    assert {:ok, result} =
             Checks.validate_all(ambiguous, ambiguous_documents, [@entity_match_rule])

    refute ValidationResult.approved?(result)
    assert [check] = result.checks
    assert check.detail =~ "Entity name mismatch: different entities"
  end

  test "mcp_tool validate_tax_id rule fails on an invalid tax id" do
    stub_defaults(validate_tax_id: fn _tax_id -> {:ok, %{valid: false}} end)

    assert {:ok, result} = Checks.validate_all(@extracted, @documents, [@tax_id_rule])
    refute ValidationResult.approved?(result)
    assert [check] = result.checks
    assert check.detail =~ "Tax ID failed validation"
  end

  test "mcp_tool screen_vendor rule fails on a sanctions hit" do
    stub_defaults(screen_vendor: fn _name -> {:ok, %{flagged: true, reason: "on watchlist"}} end)

    assert {:ok, result} = Checks.validate_all(@extracted, @documents, [@sanctions_rule])
    refute ValidationResult.approved?(result)
    assert [check] = result.checks
    assert check.detail =~ "Sanctions screening hit: on watchlist"
  end

  test "approved? is true only when every rule passes" do
    stub_defaults()

    assert {:ok, result} =
             Checks.validate_all(@extracted, @documents, [@tax_id_rule, @sanctions_rule])

    assert ValidationResult.approved?(result)
  end

  test "describe_findings joins only the failed checks' details" do
    stub_defaults(
      validate_tax_id: fn _tax_id -> {:ok, %{valid: false}} end,
      screen_vendor: fn _name -> {:ok, %{flagged: true, reason: "on watchlist"}} end
    )

    assert {:ok, result} =
             Checks.validate_all(@extracted, @documents, [@tax_id_rule, @sanctions_rule])

    findings = Checks.describe_findings(result)

    assert findings =~ "Tax ID failed validation"
    assert findings =~ "Sanctions screening hit: on watchlist"
  end

  describe "format and regex rules" do
    # Values are quoted verbatim in the source so the automatic grounding
    # check stays silent and the only check in the result is the rule's own.
    @iban_extracted %{"invoice" => %{iban: "GB82WEST12345698765432"}}
    @iban_documents %{"invoice" => "Remit to IBAN GB82WEST12345698765432, thanks."}

    defp format_rule(validator, name \\ "iban") do
      %{
        "type" => "format",
        "validator" => validator,
        "field" => %{"role" => "invoice", "name" => name}
      }
    end

    test "a format rule passes on a well-formed value" do
      assert {:ok, %ValidationResult{checks: [check]}} =
               Checks.validate_all(@iban_extracted, @iban_documents, [format_rule("iban")])

      assert check.passed
      assert check.detail == nil
    end

    test "a format rule fails a value that is the right shape but a bad checksum" do
      extracted = %{"invoice" => %{iban: "GB82WEST12345698765433"}}
      documents = %{"invoice" => "Remit to IBAN GB82WEST12345698765433, thanks."}

      assert {:ok, %ValidationResult{checks: [check]}} =
               Checks.validate_all(extracted, documents, [format_rule("iban")])

      refute check.passed
      assert check.detail =~ "mod-97"
    end

    test "a format rule makes no external call, so it needs no stubs to run" do
      # Deliberately no stub_defaults/0 here — if this rule reached the LLM
      # or an MCP server, this test would fail rather than silently pass.
      assert {:ok, %ValidationResult{checks: [check]}} =
               Checks.validate_all(@iban_extracted, @iban_documents, [format_rule("iban")])

      assert check.passed
    end

    test "a blank field is a synthesized failure, not a pass" do
      extracted = %{"invoice" => %{iban: "", vendor_name: "Acme Corp"}}
      documents = %{"invoice" => "Acme Corp sent an invoice with no IBAN on it."}

      assert {:ok, %ValidationResult{checks: checks}} =
               Checks.validate_all(extracted, documents, [format_rule("iban")])

      assert Enum.any?(checks, &(&1.detail =~ "was not extracted"))
    end

    test "an unknown validator name fails the run instead of silently doing nothing" do
      assert {:error, {:unknown_format_validator, "blockchain_integrity"}} =
               Checks.validate_all(@iban_extracted, @iban_documents, [
                 format_rule("blockchain_integrity")
               ])
    end

    test "a regex rule checks a document-type-specific shape" do
      extracted = %{"invoice" => %{order_id: "A12345"}}
      documents = %{"invoice" => "Order ID: A12345"}

      rule = %{
        "type" => "regex",
        "pattern" => "^[A-Z][0-9]{1,6}$",
        "field" => %{"role" => "invoice", "name" => "order_id"}
      }

      assert {:ok, %ValidationResult{checks: [check]}} =
               Checks.validate_all(extracted, documents, [rule])

      assert check.passed

      mismatched = %{"invoice" => %{order_id: "banana"}}
      mismatched_documents = %{"invoice" => "Order ID: banana"}

      assert {:ok, %ValidationResult{checks: [failed]}} =
               Checks.validate_all(mismatched, mismatched_documents, [rule])

      refute failed.passed
      assert failed.detail =~ "does not match the required pattern"
    end

    test "an uncompilable pattern fails the run rather than matching nothing" do
      rule = %{
        "type" => "regex",
        "pattern" => "^[unclosed",
        "field" => %{"role" => "invoice", "name" => "iban"}
      }

      assert {:error, {:invalid_regex_rule, "^[unclosed"}} =
               Checks.validate_all(@iban_extracted, @iban_documents, [rule])
    end
  end

  describe "grounded_extraction_checks/2" do
    test "returns no checks when every extracted field appears in its source document" do
      assert Checks.grounded_extraction_checks(@extracted, @documents) == []
    end

    test "flags a field fabricated from a source document that never mentions it" do
      # Reproduces a real case: an "invoice" extraction pulled a vendor
      # name, invoice number, and amount out of a cover letter that
      # contains none of them — the LLM invented an invoice wholesale
      # instead of recognizing there was nothing to extract. Nothing in
      # `invoice`'s validation_rules (just a sanctions screen on
      # vendor_name) would have caught the invoice_number/amount/due_date
      # fields at all, since no rule references them.
      extracted = %{
        "invoice" => %{
          vendor_name: "Acme Corp",
          invoice_number: "INV123456",
          amount: "$1200",
          due_date: "2023-12-01"
        }
      }

      documents = %{
        "invoice" => """
        I am writing to express my enthusiasm for the Software Engineer
        position. Sincerely, Divij Jain.
        """
      }

      checks = Checks.grounded_extraction_checks(extracted, documents)

      assert length(checks) == 4
      assert Enum.all?(checks, &(&1.passed == false))
      assert Enum.all?(checks, &(&1.rule["type"] == "grounded_extraction"))

      fields = Enum.map(checks, & &1.rule["field"]["name"])
      assert Enum.sort(fields) == [:amount, :due_date, :invoice_number, :vendor_name]
    end

    test "is case- and whitespace-insensitive" do
      extracted = %{"invoice" => %{vendor_name: "  ACME    corp  "}}
      documents = %{"invoice" => "Bill to: Acme Corp, 123 Main St."}

      assert Checks.grounded_extraction_checks(extracted, documents) == []
    end

    test "does not flag blank or missing extracted values as fabricated" do
      extracted = %{"invoice" => %{vendor_name: "", due_date: nil}}
      documents = %{"invoice" => "unrelated text"}

      assert Checks.grounded_extraction_checks(extracted, documents) == []
    end

    test "with shape_signals configured, a verbatim value far from any keyword still fails" do
      # Reproduces the résumé case: "$50M - $100M" is real, verbatim text
      # in the source — but it's describing payment volume in a work
      # history bullet, nowhere near invoice vocabulary, so plain
      # substring presence alone shouldn't be enough to trust it.
      extracted = %{"invoice" => %{amount: "$50M - $100M"}}

      documents = %{
        "invoice" => """
        Senior Software Engineer | Yolo Group
        Developed a fintech payment application driving a total daily
        volume of $50M - $100M integrated across the ecosystem.
        """
      }

      shape_signals = %{
        "invoice" => %{"keywords" => ["invoice", "bill to", "amount due"], "min_matches" => 2}
      }

      checks = Checks.grounded_extraction_checks(extracted, documents, shape_signals)

      assert [check] = checks
      assert check.rule["field"]["name"] == :amount
    end

    test "with shape_signals configured, a value near a relevant keyword passes" do
      extracted = %{"invoice" => %{amount: "1000.00"}}
      documents = %{"invoice" => "INVOICE\nAmount Due: 1000.00\n"}

      shape_signals = %{
        "invoice" => %{"keywords" => ["amount due"], "min_matches" => 1}
      }

      assert Checks.grounded_extraction_checks(extracted, documents, shape_signals) == []
    end

    test "a genuinely grounded value far from any keyword still passes, as long as the keyword is present somewhere" do
      # Reproduces the real intermittent false positive found on
      # `scanned-layout-table-01`: a due date phrased "Payment due by X"
      # (not "Due Date: X") sits far from the nearest configured keyword
      # purely because of document layout, not because the value is
      # actually ungrounded — see CONTEXT.md's dated entry. The keyword
      # ("amount", via the table header) is genuinely present in the
      # document, just nowhere near this particular value.
      extracted = %{"invoice" => %{due_date: "2026-09-20"}}

      documents = %{
        "invoice" => """
        INVOICE

        Vendor: Ironbridge Manufacturing Co.
        #{String.duplicate("Line item filler text padding the document out. ", 20)}
        Description       Qty   Rate    Amount
        Machine parts     10    45.00   450.00

        Total Due: $450.00

        Payment due by 2026-09-20.
        """
      }

      shape_signals = %{
        "invoice" => %{
          "keywords" => ["invoice", "vendor", "amount", "due date", "bill to"],
          "min_matches" => 2
        }
      }

      assert Checks.grounded_extraction_checks(extracted, documents, shape_signals) == []
    end
  end

  describe "extraction_completeness_checks/1" do
    test "returns no checks when most fields are present" do
      extracted = %{"invoice" => %{vendor_name: "Acme Corp", amount: nil}}
      assert Checks.extraction_completeness_checks(extracted) == []
    end

    test "flags a role where a majority of fields came back empty" do
      extracted = %{
        "invoice" => %{vendor_name: nil, invoice_number: nil, amount: "1000.00", due_date: nil}
      }

      assert [check] = Checks.extraction_completeness_checks(extracted)
      refute check.passed
      assert check.rule == %{"type" => "extraction_completeness", "role" => "invoice"}
      assert check.detail =~ "3/4 fields for invoice came back empty"
      assert check.detail =~ "may not actually match the invoice document type"
    end

    test "treats blank strings the same as nil" do
      extracted = %{"invoice" => %{vendor_name: "", invoice_number: "  ", amount: "1000.00"}}

      assert [check] = Checks.extraction_completeness_checks(extracted)
      refute check.passed
    end

    test "ignores a role with no fields at all" do
      assert Checks.extraction_completeness_checks(%{"invoice" => %{}}) == []
    end
  end

  describe "low_confidence_checks/2" do
    test "flags a field below the confidence threshold" do
      extracted = %{"invoice" => %{vendor_name: "Acme Corp"}}
      metadata = %{"invoice" => %{vendor_name: %{confidence: 0.4, source_quote: "Acme Corp"}}}

      assert [check] = Checks.low_confidence_checks(extracted, metadata)
      refute check.passed

      assert check.rule == %{
               "type" => "low_confidence",
               "field" => %{"role" => "invoice", "name" => :vendor_name}
             }

      assert check.detail =~ "low model-reported confidence (0.4)"
    end

    test "does not flag a field at or above the threshold" do
      extracted = %{"invoice" => %{vendor_name: "Acme Corp"}}
      metadata = %{"invoice" => %{vendor_name: %{confidence: 0.7, source_quote: "Acme Corp"}}}

      assert Checks.low_confidence_checks(extracted, metadata) == []
    end

    test "does not flag a field with nil confidence — not attempted is not the same as low confidence" do
      extracted = %{"invoice" => %{vendor_name: nil}}
      metadata = %{"invoice" => %{vendor_name: %{confidence: nil, source_quote: nil}}}

      assert Checks.low_confidence_checks(extracted, metadata) == []
    end

    test "does not flag a field with no metadata entry at all" do
      extracted = %{"invoice" => %{vendor_name: "Acme Corp"}}
      assert Checks.low_confidence_checks(extracted, %{}) == []
    end

    test "a regex-resolved field's synthesized 1.0 confidence never gets flagged" do
      extracted = %{"w9" => %{tax_id: "12-3456789"}}
      metadata = %{"w9" => %{tax_id: %{confidence: 1.0, source_quote: "12-3456789"}}}

      assert Checks.low_confidence_checks(extracted, metadata) == []
    end
  end

  describe "not_expired rule" do
    @expiry_rule %{
      "type" => "not_expired",
      "field" => %{"role" => "coi", "name" => "expiry_date"}
    }

    defp expiry_check(value, today) do
      extracted = %{"coi" => %{expiry_date: value}}
      documents = %{"coi" => "CERTIFICATE OF INSURANCE. Expires: #{value}"}

      assert {:ok, result} =
               Checks.validate_all(extracted, documents, [@expiry_rule], today: today)

      Enum.find(result.checks, &(&1.rule["type"] == "not_expired"))
    end

    test "passes for a date in the future" do
      assert %{passed: true} = expiry_check("2027-03-14", ~D[2026-09-01])
    end

    test "passes on the expiry date itself — a certificate is valid until it lapses" do
      assert %{passed: true} = expiry_check("2026-09-01", ~D[2026-09-01])
    end

    test "fails for a date in the past, saying how far past" do
      check = expiry_check("2026-08-01", ~D[2026-09-01])

      refute check.passed
      assert check.detail =~ "Expired"
      assert check.detail =~ "31 day(s) before today"
      assert check.detail =~ "2026-09-01"
    end

    test "the clock is injected, so a fixture doesn't rot into a failure" do
      # The same value, judged from two different days.
      assert %{passed: true} = expiry_check("2026-12-31", ~D[2026-09-01])
      assert %{passed: false} = expiry_check("2026-12-31", ~D[2027-01-01])
    end

    test "reports an ambiguous date as undecidable rather than picking a reading" do
      check = expiry_check("01/02/2027", ~D[2026-09-01])

      refute check.passed
      assert check.detail =~ "not a date that can be read one way only"
    end

    test "a missing date is a finding, not a pass" do
      extracted = %{"coi" => %{expiry_date: nil}}

      assert {:ok, result} =
               Checks.validate_all(extracted, %{"coi" => "x"}, [@expiry_rule],
                 today: ~D[2026-09-01]
               )

      assert [check] = Enum.filter(result.checks, &(&1.rule["type"] == "not_expired"))
      refute check.passed
      assert check.detail =~ "was not extracted"
    end

    test "defaults to the real today when no clock is supplied" do
      # Nothing to stub: a date far enough in the past is expired whenever
      # this test happens to run.
      extracted = %{"coi" => %{expiry_date: "2001-01-01"}}
      documents = %{"coi" => "expires 2001-01-01"}

      assert {:ok, result} = Checks.validate_all(extracted, documents, [@expiry_rule])
      assert [check] = Enum.filter(result.checks, &(&1.rule["type"] == "not_expired"))
      refute check.passed
    end
  end

  describe "declared_type_checks/3" do
    @invoice_schema %{
      "invoice" => %{
        "vendor_name" => %{"type" => "string"},
        "amount" => %{"type" => "monetary_amount"},
        "due_date" => %{"type" => "date"}
      }
    }

    test "passes silently when every typed value is well-formed" do
      extracted = %{
        "invoice" => %{vendor_name: "Acme Corp", amount: "$1,275.00", due_date: "2026-09-01"}
      }

      assert Checks.declared_type_checks(extracted, @invoice_schema) == []
    end

    test "flags a value that isn't well-formed for its declared type" do
      extracted = %{
        "invoice" => %{vendor_name: "Acme Corp", amount: "twelve hundred", due_date: "2026-09-01"}
      }

      assert [check] = Checks.declared_type_checks(extracted, @invoice_schema)

      refute check.passed
      assert check.rule["type"] == "declared_field_type"
      assert check.rule["declared_type"] == "monetary_amount"
      assert check.rule["field"] == %{"role" => "invoice", "name" => :amount}
      assert check.detail =~ "declared as monetary_amount"
      assert check.detail =~ "twelve hundred"
    end

    test "flags every badly-typed field, not just the first" do
      extracted = %{
        "invoice" => %{vendor_name: "Acme", amount: "N/A", due_date: "sometime next spring"}
      }

      assert [_one, _two] = Checks.declared_type_checks(extracted, @invoice_schema)
    end

    test "a string-typed field has no shape to be wrong about" do
      # vendor_name would fail every validator in the module; being
      # declared free text is exactly what makes that fine.
      extracted = %{"invoice" => %{vendor_name: "N/A"}}

      assert Checks.declared_type_checks(extracted, @invoice_schema) == []
    end

    test "a blank or missing value is left to extraction_completeness_checks/1" do
      extracted = %{"invoice" => %{amount: nil, due_date: "  "}}

      assert Checks.declared_type_checks(extracted, @invoice_schema) == []
    end

    test "a role with no schema entry at all is skipped rather than crashing" do
      extracted = %{"receipt" => %{total: "not a number"}}

      assert Checks.declared_type_checks(extracted, @invoice_schema) == []
    end

    test "an explicit format rule on the same field and validator wins, so one finding not two" do
      extracted = %{"invoice" => %{amount: "twelve hundred"}}

      rule = %{
        "type" => "format",
        "validator" => "monetary_amount",
        "field" => %{"role" => "invoice", "name" => "amount"}
      }

      assert Checks.declared_type_checks(extracted, @invoice_schema, [rule]) == []
    end

    test "an explicit format rule naming a different validator is additional, not a duplicate" do
      extracted = %{"invoice" => %{amount: "twelve hundred"}}

      rule = %{
        "type" => "format",
        "validator" => "number",
        "field" => %{"role" => "invoice", "name" => "amount"}
      }

      assert [_check] = Checks.declared_type_checks(extracted, @invoice_schema, [rule])
    end
  end

  describe "validate_all/4 with a declared extraction_schema" do
    test "runs the declared-type check automatically, with no rule configured for it" do
      stub_defaults()

      extracted = %{"invoice" => %{vendor_name: "Acme Corp", amount: "twelve hundred"}}
      documents = %{"invoice" => "INVOICE from Acme Corp. Amount Due: twelve hundred"}

      assert {:ok, result} =
               Checks.validate_all(extracted, documents, [],
                 extraction_schema: %{
                   "invoice" => %{
                     "vendor_name" => %{"type" => "string"},
                     "amount" => %{"type" => "monetary_amount"}
                   }
                 }
               )

      # The value is verbatim from the document, so grounding passes — this
      # is the check catching what grounding structurally cannot.
      assert [check] = ValidationResult.failed_checks(result)
      assert check.rule["type"] == "declared_field_type"
    end

    test "without an extraction_schema nothing is type-checked" do
      stub_defaults()

      extracted = %{"invoice" => %{amount: "twelve hundred"}}
      documents = %{"invoice" => "INVOICE. Amount Due: twelve hundred"}

      assert {:ok, result} = Checks.validate_all(extracted, documents, [])
      assert ValidationResult.failed_checks(result) == []
    end
  end

  describe "staged_match/2" do
    test "returns a match without needing the LLM for near-identical names" do
      assert {:ok, %EntityMatchResult{match: true}} =
               Checks.staged_match("Acme Corp", "Acme Corp")
    end

    test "returns a non-match without needing the LLM for clearly different names" do
      assert {:ok, %EntityMatchResult{match: false}} =
               Checks.staged_match("Acme Corp", "Totally Different LLC")
    end

    test "is ambiguous for a genuine formatting difference, deferring to the LLM" do
      assert :ambiguous = Checks.staged_match("Acme Corp", "Acme Corporation")
    end
  end

  describe "entity_match/2 staging" do
    test "skips the configured LLM fake entirely for a clear match" do
      test_pid = self()

      stub(entity_match: fn _a, _b -> send(test_pid, :llm_called) end)

      assert {:ok, %EntityMatchResult{match: true}} =
               Checks.entity_match("Acme Corp", "Acme Corp")

      refute_received :llm_called
    end

    test "skips the configured LLM fake entirely for a clear mismatch" do
      test_pid = self()

      stub(entity_match: fn _a, _b -> send(test_pid, :llm_called) end)

      assert {:ok, %EntityMatchResult{match: false}} =
               Checks.entity_match("Acme Corp", "Totally Different LLC")

      refute_received :llm_called
    end

    test "falls through to the configured LLM fake for an ambiguous formatting difference" do
      test_pid = self()

      stub(
        entity_match: fn a, b ->
          send(test_pid, {:llm_called, a, b})
          {:ok, %EntityMatchResult{match: true, explanation: "same entity"}}
        end
      )

      assert {:ok, %EntityMatchResult{match: true, explanation: "same entity"}} =
               Checks.entity_match("Acme Corp", "Acme Corporation")

      assert_received {:llm_called, "Acme Corp", "Acme Corporation"}
    end
  end
end
