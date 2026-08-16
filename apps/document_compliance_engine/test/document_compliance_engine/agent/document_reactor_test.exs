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

  defp base_inputs(overrides) do
    Map.merge(
      %{
        document_type_slug: "vendor_contract_w9",
        documents: %{"contract" => "c", "w9" => "w"},
        extraction_schema: @extraction_schema,
        validation_rules: @validation_rules,
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

  test "halts for review on invalid tax id" do
    stub_defaults(validate_tax_id: fn _tax_id -> {:ok, %{valid: false}} end)

    assert {:halted, reactor} = run()
    assert {:awaiting_human, explanation} = reactor.intermediate_results[:gate]
    assert explanation =~ "Tax ID failed validation"
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
