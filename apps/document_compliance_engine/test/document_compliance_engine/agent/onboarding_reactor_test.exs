defmodule DocumentComplianceEngine.Agent.OnboardingReactorTest do
  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.OnboardingReactor

  defp run(inputs \\ %{}) do
    Reactor.run(
      OnboardingReactor,
      Map.merge(%{contract_text: "c", w9_text: "w", human_decision: nil}, inputs)
    )
  end

  test "auto-approves when everything matches and validates" do
    stub_defaults()

    assert {:ok, result} = run()
    assert result.status == "approved"
  end

  test "halts for review on entity name mismatch" do
    stub_defaults(extract_w9: fn _text -> {:ok, w9(%{company_name: "Totally Different LLC"})} end)

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
    stub_defaults(extract_w9: fn _text -> {:ok, w9(%{company_name: "Totally Different LLC"})} end)

    assert {:halted, reactor} = run()

    revived = reactor |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert {:ok, result} =
             Reactor.run(
               revived,
               %{contract_text: "c", w9_text: "w", human_decision: "rejected"},
               %{}
             )

    assert result.status == "rejected"
  end

  test "resuming does not re-run the extraction steps" do
    # Resume must not repeat LLM calls — that's what makes the checkpoint
    # a real equivalent of the one it replaces.
    test_pid = self()

    stub_defaults(
      extract_contract: fn _text ->
        Kernel.send(test_pid, :extracted_contract)
        {:ok, contract()}
      end,
      extract_w9: fn _text -> {:ok, w9(%{company_name: "Totally Different LLC"})} end
    )

    assert {:halted, reactor} = run()
    assert_received :extracted_contract

    assert {:ok, _result} =
             Reactor.run(
               reactor,
               %{contract_text: "c", w9_text: "w", human_decision: "approved"},
               %{}
             )

    refute_received :extracted_contract
  end
end
