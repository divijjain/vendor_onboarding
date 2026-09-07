defmodule DocumentComplianceEngine.Agent.DocumentReactor do
  @moduledoc """
  The agent pipeline: work out which document type this job is, extract
  every role that type defines, validate against its configured rules,
  then either auto-approve or halt for human review. Generic over the
  document type in both directions now — which type applies is itself a
  step (`:classify`), and the extraction fields and validation rules are
  data read from whichever type wins (`:resolve_type`).

  **What is an input and what is a step.** The candidate document types
  (`:document_types`) are still resolved by the caller before
  `Reactor.run/2` and passed in whole: that is a static, idempotent config
  read with no pause/retry need, and it keeps the checkpoint's stored
  `inputs` self-contained for resume, the same property the
  previously-passed `extraction_schema` had. What *changed* is that the
  schema for this particular run is no longer knowable before the run —
  it depends on the classification — so it moved from an input to
  `:resolve_type`'s result. The static config is still an input; only the
  choice among it became a step.

  **Not knowing is a finding, not control flow.** An unconfident
  classification, an unclassifiable document, or documents that don't line
  up with the chosen type's roles all resolve to an empty
  `extraction_schema` plus a failed check (`TypeResolution`). Extraction
  over no roles is a real no-op, and the check flows into the same
  `ValidationResult` as an entity mismatch or a sanctions hit, so the run
  halts at the same `:gate` for the same reviewer with the same audit
  trail. There is deliberately no second pause mechanism and no
  conditional step.

  The `:gate`/`:finalize` split is load-bearing, not stylistic. Reactor
  treats a step's `{:halt, value}` as that step's *final* result — it is
  never re-executed on resume. So the human's decision cannot be read by
  the step that halts; it has to land in a step that hasn't run yet.
  `:finalize` is that step. Collapsing the two would silently return the
  stale halt value instead of the human's decision.
  """

  use Reactor

  alias DocumentComplianceEngine.Agent.Checks
  alias DocumentComplianceEngine.Agent.Classification
  alias DocumentComplianceEngine.Agent.Extraction
  alias DocumentComplianceEngine.Agent.TypeResolution
  alias DocumentComplianceEngine.Agent.ValidationResult

  # nil when the caller didn't say what they were sending — the case
  # `:classify` exists for. A supplied slug is honoured, not re-derived.
  input(:document_type_slug)
  # role => text, keyed however the caller uploaded them. `:resolve_type`
  # re-keys these onto the chosen type's roles.
  input(:documents)
  # Every document type in the registry, as string-keyed config.
  input(:document_types)
  # nil on the initial run; supplied when resuming after human review.
  input(:human_decision)

  step :classify do
    argument(:documents, input(:documents))
    argument(:document_types, input(:document_types))
    argument(:document_type_slug, input(:document_type_slug))

    run(fn %{
             documents: documents,
             document_types: candidates,
             document_type_slug: slug
           },
           _context ->
      Classification.classify(documents, candidates, slug)
    end)
  end

  step :resolve_type do
    argument(:classification, result(:classify))
    argument(:documents, input(:documents))
    argument(:document_types, input(:document_types))

    run(fn %{classification: classification, documents: documents, document_types: candidates},
           _context ->
      {:ok, TypeResolution.resolve(classification, candidates, documents)}
    end)
  end

  step :extract do
    argument(:documents, result(:resolve_type, [:documents]))
    argument(:extraction_schema, result(:resolve_type, [:extraction_schema]))
    argument(:shape_signals, result(:resolve_type, [:shape_signals]))

    run(fn %{documents: documents, extraction_schema: schema, shape_signals: shape_signals},
           _context ->
      case Extraction.extract_all(documents, schema, shape_signals) do
        {:ok, fields, metadata} -> {:ok, %{fields: fields, metadata: metadata}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  step :validate do
    argument(:extracted, result(:extract, [:fields]))
    argument(:extraction_metadata, result(:extract, [:metadata]))
    # Every argument below comes from the resolved type, including the
    # documents: `Checks` grounds values against the same re-keyed text
    # `:extract` read them from, not the caller's original keys.
    argument(:resolved, result(:resolve_type))

    run(fn %{extracted: extracted, extraction_metadata: extraction_metadata, resolved: resolved},
           _context ->
      with {:ok, validation} <-
             Checks.validate_all(extracted, resolved.documents, resolved.validation_rules,
               shape_signals: resolved.shape_signals,
               extraction_metadata: extraction_metadata,
               extraction_schema: resolved.extraction_schema
             ) do
        # Classification findings are checks like any other, and lead the
        # list: "we may have the wrong type" is the finding that frames
        # every other finding below it.
        {:ok, %ValidationResult{validation | checks: resolved.checks ++ validation.checks}}
      end
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
    argument(:extracted, result(:extract, [:fields]))
    argument(:extraction_metadata, result(:extract, [:metadata]))
    # The *resolved* slug, which is what this run actually used — not the
    # caller's input, which may have been nil.
    argument(:document_type_slug, result(:resolve_type, [:document_type_slug]))
    argument(:human_decision, input(:human_decision))

    run(fn args, _context ->
      status =
        case args.gate do
          :auto_approved -> "approved"
          {:awaiting_human, _explanation} -> args.human_decision
        end

      {:ok,
       %{
         status: status,
         document_type_slug: args.document_type_slug,
         extracted: args.extracted,
         extraction_metadata: args.extraction_metadata
       }}
    end)
  end
end
