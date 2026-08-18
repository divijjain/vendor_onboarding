defmodule DocumentComplianceEngine.Agent.DocumentReactorTest do
  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.DocumentReactor

  @extraction_schema %{
    "contract" => %{
      "company_name" => "string",
      "payment_terms" => "string",
      "liability_clauses" => "string"
    },
    "w9" => %{"company_name" => "string", "tax_id" => "string"}
  }

  @validation_rules [
    %{
      "type" => "entity_match",
      "fields" => [
        %{"role" => "contract", "name" => "company_name"},
        %{"role" => "w9", "name" => "company_name"}
      ]
    },
    %{
      "type" => "mcp_tool",
      "tool" => "validate_tax_id",
      "field" => %{"role" => "w9", "name" => "tax_id"}
    },
    %{
      "type" => "mcp_tool",
      "tool" => "screen_vendor",
      "field" => %{"role" => "contract", "name" => "company_name"}
    }
  ]

  # Matches `AgentFakes.contract/1`/`w9/1`'s fake extracted values verbatim
  # — required now that the reactor's groundedness check (see checks.ex)
  # halts any run whose extracted fields don't appear in these documents.
  @documents %{
    "contract" => "Contract with Acme Corp. Payment Terms: Net 30. Liability: Standard.",
    "w9" => "Form W-9. Name of entity: Acme Corp. EIN: 12-3456789."
  }

  defp base_inputs(overrides) do
    Map.merge(
      %{
        document_type_slug: "vendor_contract_w9",
        documents: @documents,
        extraction_schema: @extraction_schema,
        validation_rules: @validation_rules,
        shape_signals: %{},
        human_decision: nil
      },
      overrides
    )
  end

  defp run(overrides \\ %{}) do
    Reactor.run(DocumentReactor, base_inputs(overrides))
  end

  test "auto-approves when everything matches and validates" do
    stub_defaults()

    assert {:ok, result} = run()
    assert result.status == "approved"
  end

  test "halts for review on entity name mismatch" do
    stub_defaults(
      extract: fn
        "w9", _schema, _text -> {:ok, w9(%{company_name: "Totally Different LLC"})}
        role, schema, text -> extract(role, schema, text)
      end
    )

    assert {:halted, reactor} = run()
    assert {:awaiting_human, explanation} = reactor.intermediate_results[:gate]
    assert explanation =~ "Entity name mismatch"
  end

  test "carries confidence + source_quote through to the final result" do
    stub_defaults(
      extract: fn
        "contract", _schema, _text ->
          {:ok, contract(), %{company_name: %{confidence: 0.92, source_quote: "Acme Corp"}}}

        "w9", schema, text ->
          extract("w9", schema, text)
      end
    )

    assert {:ok, result} = run()
    assert result.extraction_metadata["contract"].company_name.confidence == 0.92
    assert result.extraction_metadata["contract"].company_name.source_quote == "Acme Corp"
  end

  test "halts for review on a field the model itself reported low confidence on" do
    stub_defaults(
      extract: fn
        "contract", _schema, _text ->
          {:ok, contract(), %{company_name: %{confidence: 0.3, source_quote: "Acme Corp"}}}

        "w9", schema, text ->
          extract("w9", schema, text)
      end
    )

    assert {:halted, reactor} = run()
    assert {:awaiting_human, explanation} = reactor.intermediate_results[:gate]
    assert explanation =~ "low model-reported confidence"
  end

  test "halts for review on invalid tax id" do
    stub_defaults(validate_tax_id: fn _tax_id -> {:ok, %{valid: false}} end)

    assert {:halted, reactor} = run()
    assert {:awaiting_human, explanation} = reactor.intermediate_results[:gate]
    assert explanation =~ "Tax ID failed validation"
  end

  test "halts for review on a fabricated field, even with no rule referencing it" do
    # Reproduces a real case: an "invoice" extraction pulled a vendor name,
    # invoice number, and amount out of a document that mentions none of
    # them — the LLM invented an invoice wholesale. `screen_vendor` is the
    # only configured rule and it passes (a fabricated name doesn't hit a
    # real watchlist), so nothing but the groundedness check catches this.
    stub_defaults(
      extract: fn "invoice", _schema, _text ->
        {:ok,
         %{
           vendor_name: "Acme Corp",
           invoice_number: "INV123456",
           amount: "$1200",
           due_date: "2023-12-01"
         }}
      end
    )

    assert {:halted, reactor} =
             run(%{
               document_type_slug: "invoice",
               documents: %{
                 "invoice" => "I am writing to express my enthusiasm for this position."
               },
               extraction_schema: %{
                 "invoice" => %{
                   "vendor_name" => "string",
                   "invoice_number" => "string",
                   "amount" => "string",
                   "due_date" => "string"
                 }
               },
               validation_rules: [
                 %{
                   "type" => "mcp_tool",
                   "tool" => "screen_vendor",
                   "field" => %{"role" => "invoice", "name" => "vendor_name"}
                 }
               ]
             })

    assert {:awaiting_human, explanation} = reactor.intermediate_results[:gate]
    assert explanation =~ "possible hallucination"
  end

  test "halts for review before ever calling extraction, when a résumé fails the shape gate" do
    # The other half of the real case above: this time `shape_signals` is
    # configured (mirroring the real seeded `invoice` document type), so a
    # résumé that only coincidentally mentions "Vendor" once never reaches
    # the LLM at all — the shape gate skips it, `extraction_completeness`
    # catches the resulting all-nil role, and the run halts having spent
    # zero extraction calls.
    test_pid = self()
    stub_defaults(extract: fn role, _schema, _text -> send(test_pid, {:called, role}) end)

    assert {:halted, reactor} =
             run(%{
               document_type_slug: "invoice",
               documents: %{
                 "invoice" => """
                 Senior Software Engineer | Yolo Group
                 Architected an agentic pipeline automating document
                 extraction and validation for Vendor Onboarding.
                 """
               },
               extraction_schema: %{
                 "invoice" => %{
                   "vendor_name" => "string",
                   "invoice_number" => "string",
                   "amount" => "string",
                   "due_date" => "string"
                 }
               },
               shape_signals: %{
                 "invoice" => %{
                   "keywords" => ["invoice", "vendor", "amount", "due date", "bill to"],
                   "min_matches" => 2
                 }
               },
               validation_rules: [
                 %{
                   "type" => "mcp_tool",
                   "tool" => "screen_vendor",
                   "field" => %{"role" => "invoice", "name" => "vendor_name"}
                 }
               ]
             })

    refute_received {:called, "invoice"}
    assert {:awaiting_human, explanation} = reactor.intermediate_results[:gate]
    assert explanation =~ "may not actually match the invoice document type"
  end

  test "halts for review on a sanctions hit" do
    stub_defaults(
      screen_vendor: fn _name -> {:ok, %{flagged: true, reason: "Matched watchlist entry"}} end
    )

    assert {:halted, reactor} = run()
    assert {:awaiting_human, explanation} = reactor.intermediate_results[:gate]
    assert explanation =~ "Sanctions screening hit"
  end

  test "a halted run survives serialization and resumes with the human's decision" do
    # The durable-pause guarantee: a paused review must survive this
    # service restarting, so the checkpoint is exercised as a real
    # round-trip through binary, not by reusing the in-memory struct.
    stub_defaults(
      extract: fn
        "w9", _schema, _text -> {:ok, w9(%{company_name: "Totally Different LLC"})}
        role, schema, text -> extract(role, schema, text)
      end
    )

    assert {:halted, reactor} = run()

    revived = reactor |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert {:ok, result} = Reactor.run(revived, base_inputs(%{human_decision: "rejected"}), %{})

    assert result.status == "rejected"
  end

  test "resuming does not re-run the extraction step" do
    # Resume must not repeat LLM calls — that's what makes the checkpoint
    # a real equivalent of the one it replaces.
    test_pid = self()

    stub_defaults(
      extract: fn
        "contract", schema, text ->
          Kernel.send(test_pid, :extracted_contract)
          extract("contract", schema, text)

        "w9", _schema, _text ->
          {:ok, w9(%{company_name: "Totally Different LLC"})}
      end
    )

    assert {:halted, reactor} = run()
    assert_received :extracted_contract

    assert {:ok, _result} = Reactor.run(reactor, base_inputs(%{human_decision: "approved"}), %{})

    refute_received :extracted_contract
  end
end
