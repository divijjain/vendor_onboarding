defmodule DocumentComplianceEngine.Agent.OnboardingReactor do
  @moduledoc """
  The agent pipeline: extract both documents, validate, then either
  auto-approve or halt for human review.

  The `:gate`/`:finalize` split is load-bearing, not stylistic. Reactor
  treats a step's `{:halt, value}` as that step's *final* result — it is
  never re-executed on resume. So the human's decision cannot be read by
  the step that halts; it has to land in a step that hasn't run yet.
  `:finalize` is that step. Collapsing the two would silently return the
  stale halt value instead of the human's decision.
  """

  use Reactor

  alias DocumentComplianceEngine.Agent.{Checks, Extraction, ValidationResult}

  input(:contract_text)
  input(:w9_text)
  # nil on the initial run; supplied when resuming after human review.
  input(:human_decision)

  step :extract_contract do
    argument(:text, input(:contract_text))
    run(fn %{text: text}, _context -> Extraction.extract_contract(text) end)
  end

  step :extract_w9 do
    argument(:text, input(:w9_text))
    run(fn %{text: text}, _context -> Extraction.extract_w9(text) end)
  end

  step :validate do
    argument(:contract, result(:extract_contract))
    argument(:w9, result(:extract_w9))
    run(&Checks.validate/1)
  end

  step :gate do
    argument(:validation, result(:validate))

    run(fn %{validation: validation}, _context ->
      if ValidationResult.approved?(validation) do
        {:ok, :auto_approved}
      else
        {:halt, {:awaiting_human, Checks.draft_explanation(validation)}}
      end
    end)
  end

  step :finalize do
    argument(:gate, result(:gate))
    argument(:contract, result(:extract_contract))
    argument(:w9, result(:extract_w9))
    argument(:human_decision, input(:human_decision))

    run(fn args, _context ->
      status =
        case args.gate do
          :auto_approved -> "approved"
          {:awaiting_human, _explanation} -> args.human_decision
        end

      {:ok, %{status: status, contract: args.contract, w9: args.w9}}
    end)
  end
end
