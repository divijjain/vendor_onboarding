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
