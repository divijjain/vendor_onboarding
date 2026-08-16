defmodule DocumentComplianceEngine.Agent.DocumentReactor do
  @moduledoc """
  The agent pipeline: extract every document role a document type defines,
  validate against that type's configured rules, then either auto-approve
  or halt for human review. Generic over `document_type_slug` — extraction
  fields and validation rules are data (`extraction_schema`/
  `validation_rules`, resolved by the caller before `Reactor.run/2` and
  passed in as plain inputs, not looked up as a Reactor step: it's a
  static, idempotent config read with no pause/retry need, and keeping it
  outside Reactor keeps the checkpoint's stored `inputs` self-contained
  for resume, same as every other input here).

  The `:gate`/`:finalize` split is load-bearing, not stylistic. Reactor
  treats a step's `{:halt, value}` as that step's *final* result — it is
  never re-executed on resume. So the human's decision cannot be read by
  the step that halts; it has to land in a step that hasn't run yet.
  `:finalize` is that step. Collapsing the two would silently return the
  stale halt value instead of the human's decision.
  """

  use Reactor

  alias DocumentComplianceEngine.Agent.{Checks, Extraction, ValidationResult}

  input(:document_type_slug)
  input(:documents)
  input(:extraction_schema)
  input(:validation_rules)
  # nil on the initial run; supplied when resuming after human review.
  input(:human_decision)

  step :extract do
    argument(:documents, input(:documents))
    argument(:extraction_schema, input(:extraction_schema))

    run(fn %{documents: documents, extraction_schema: schema}, _context ->
      Extraction.extract_all(documents, schema)
    end)
  end

  step :validate do
    argument(:extracted, result(:extract))
    argument(:validation_rules, input(:validation_rules))

    run(fn %{extracted: extracted, validation_rules: rules}, _context ->
      Checks.validate_all(extracted, rules)
    end)
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
    argument(:extracted, result(:extract))
    argument(:document_type_slug, input(:document_type_slug))
    argument(:human_decision, input(:human_decision))

    run(fn args, _context ->
      status =
        case args.gate do
          :auto_approved -> "approved"
          {:awaiting_human, _explanation} -> args.human_decision
        end

      {:ok,
       %{status: status, document_type_slug: args.document_type_slug, extracted: args.extracted}}
    end)
  end
end
