defmodule DocumentComplianceEngine.Agent.Evals.Run do
  @moduledoc """
  Eval harness — drives the reactor directly, bypassing Phoenix, so
  agent-quality eval is isolated from integration latency/correctness
  (CONTEXT.md's evaluation-design decision). Reads each fixture's own real
  `DocumentType` row (extraction schema + validation rules + shape
  signals) via `DocumentTypes`, rather than duplicating that config here,
  so the harness can't silently drift from what production actually runs
  — genuinely document-type-generic, not hardcoded to one slug: a fixture
  carries its own `document_type_slug`, so `run_all/2` can be handed a mix
  of `vendor_contract_w9` and `invoice` fixtures (or any future type) in
  one pass. Most fixtures carry pre-extracted `documents` text and skip
  straight to the reactor; the `scanned` bucket instead carries
  `image_paths` and is run through `PdfText.extract/1` first by
  `build_documents/1` — the one place this harness exercises the
  vision-transcription fallback against real image bytes, see
  `Fixtures`' moduledoc and CONTEXT.md's dated entry.

  Two tiers:
    - Deterministic (always runs, no judge key needed): Tax ID
      verbatim-in-source (`vendor_contract_w9` only), whether *every*
      extracted field across every role is grounded in its source
      document (any type — reuses `Agent.Checks.grounded_extraction_checks/3`,
      the same check that gates the live pipeline), and whether the run
      completed at all (graceful degradation on the malformed buckets).
    - LLM-judge (Claude Sonnet, only if ANTHROPIC_API_KEY is set):
      entity-mapping correctness under formatting variation
      (`vendor_contract_w9` only — invoice has no entity-match concept),
      and groundedness of drafted mismatch explanations (any type).

  The agents themselves need OPENAI_API_KEY regardless of the judge tier.

      mix eval.run
  """

  alias DocumentComplianceEngine.Agent.Evals.{Deterministic, Fixtures, Judge}
  alias DocumentComplianceEngine.Agent.{Checks, DocumentReactor}
  alias DocumentComplianceEngine.DocumentTypes
  alias DocumentComplianceEngine.PdfText

  defmodule Result do
    @moduledoc false
    defstruct [
      :fixture,
      :decision,
      :entity_match,
      :tax_id_verbatim_ok,
      :fields_grounded,
      :field_confidences,
      :explanation,
      :findings,
      :error
    ]
  end

  @concurrency 5

  @spec run_all([Fixtures.Fixture.t()], keyword()) :: [%Result{}]
  def run_all(fixtures \\ Fixtures.all(), opts \\ []) do
    reactor = Keyword.get(opts, :reactor, DocumentReactor)

    fixtures
    # Bounded, not unbounded — firing every fixture at once against a real
    # account risks tripping rate limits for no benefit.
    |> Task.async_stream(&run_fixture(&1, reactor),
      max_concurrency: Keyword.get(opts, :concurrency, @concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp fetch_document_type!(slug) do
    DocumentTypes.get_document_type_by_slug(slug) || raise "document type #{slug} is not seeded"
  end

  @spec run_fixture(Fixtures.Fixture.t(), module(), DocumentTypes.Schema.DocumentType.t() | nil) ::
          %Result{}
  def run_fixture(fixture, reactor \\ DocumentReactor, document_type \\ nil) do
    document_type = document_type || fetch_document_type!(fixture.document_type_slug)

    case build_documents(fixture) do
      {:ok, documents} ->
        inputs = %{
          document_type_slug: fixture.document_type_slug,
          documents: documents,
          extraction_schema: document_type.extraction_schema,
          validation_rules: document_type.validation_rules,
          shape_signals: document_type.shape_signals,
          human_decision: nil
        }

        reactor
        |> Reactor.run(inputs)
        |> to_result(fixture, document_type, documents)

      {:error, reason} ->
        %Result{fixture: fixture, error: inspect(reason)}
    end
  end

  # Plain-text fixtures (`documents` set) go straight to the reactor, same
  # as always. Image-backed fixtures (`image_paths` set — the `scanned`
  # bucket) get read off disk and run through `PdfText.extract/1` first,
  # exactly like production's `Agent.Run.read_documents/2` does with a
  # webhook's uploaded bytes — so this is the one place the eval harness
  # actually exercises the vision-transcription fallback, not just the
  # plain-text reactor path.
  defp build_documents(%Fixtures.Fixture{image_paths: image_paths})
       when is_map(image_paths) and map_size(image_paths) > 0 do
    Enum.reduce_while(image_paths, {:ok, %{}}, fn {role, path}, {:ok, acc} ->
      with {:ok, bytes} <- File.read(path),
           {:ok, text} <- PdfText.extract(bytes) do
        {:cont, {:ok, Map.put(acc, role, text)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_documents(fixture), do: {:ok, fixture.documents}

  defp to_result({:ok, final}, fixture, document_type, documents) do
    tax_id = get_in(final.extracted, ["w9", :tax_id])

    %Result{
      fixture: fixture,
      decision: "approved",
      # Approval requires every configured rule to have passed, so an
      # entity_match rule (when this type has one) is known true here
      # without re-reading the (completed) validation step.
      entity_match: if(fixture.expected_entity_match != nil, do: true),
      tax_id_verbatim_ok: tax_id_verbatim_ok(documents, tax_id),
      fields_grounded: fields_grounded?(final.extracted, documents, document_type),
      field_confidences:
        field_confidences(final.extracted, final.extraction_metadata, documents, document_type)
    }
  end

  defp to_result({:halted, reactor}, fixture, document_type, documents) do
    results = reactor.intermediate_results || %{}
    validation = results[:validate]
    extract_result = results[:extract] || %{}
    extracted = extract_result[:fields] || %{}
    metadata = extract_result[:metadata] || %{}
    tax_id = get_in(extracted, ["w9", :tax_id])

    explanation =
      case results[:gate] do
        {:awaiting_human, explanation} -> explanation
        _ -> nil
      end

    entity_match_check =
      validation && Enum.find(validation.checks, &(&1.rule["type"] == "entity_match"))

    %Result{
      fixture: fixture,
      decision: "needs_review",
      entity_match: entity_match_check && entity_match_check.passed,
      tax_id_verbatim_ok: tax_id_verbatim_ok(documents, tax_id),
      fields_grounded: fields_grounded?(extracted, documents, document_type),
      field_confidences: field_confidences(extracted, metadata, documents, document_type),
      explanation: explanation,
      findings: validation && Checks.describe_findings(validation)
    }
  end

  defp to_result({:error, reason}, fixture, _document_type, _documents) do
    # Graceful degradation is itself a measured outcome, not a harness
    # crash — exactly what the malformed buckets test for.
    %Result{fixture: fixture, error: inspect(reason)}
  end

  defp tax_id_verbatim_ok(documents, tax_id) do
    case Map.get(documents, "w9") do
      nil -> nil
      w9_text -> Deterministic.tax_id_verbatim?(tax_id, w9_text)
    end
  end

  defp fields_grounded?(extracted, documents, document_type) do
    Deterministic.fields_grounded?(extracted, documents, document_type.shape_signals)
  end

  # `:tax_id` is deliberately excluded — its confidence is either a
  # synthesized `1.0` (regex-resolved, no model call at all) or a real LLM
  # call, and the two are indistinguishable from `extraction_metadata`
  # alone (see `Extraction.regex_metadata/1`). Mixing synthesized
  # confidence into a calibration meant to measure the *model's own*
  # self-report would silently bias it toward high-confidence/grounded,
  # not a real read on whether confidence predicts correctness.
  @calibration_excluded_field :tax_id

  defp field_confidences(extracted, metadata, documents, document_type) do
    ungrounded =
      extracted
      |> Checks.grounded_extraction_checks(documents, document_type.shape_signals)
      |> MapSet.new(&{&1.rule["field"]["role"], &1.rule["field"]["name"]})

    for {role, fields} <- extracted,
        {field, value} <- fields,
        field != @calibration_excluded_field,
        is_binary(value),
        confidence = get_in(metadata, [role, field, :confidence]),
        is_number(confidence) do
      %{
        role: role,
        field: field,
        confidence: confidence,
        grounded: not MapSet.member?(ungrounded, {role, field})
      }
    end
  end

  @doc """
  Per-field self-reported confidence, bucketed by whether that field's own
  value actually passed the deterministic grounding check — the empirical
  question `Checks.low_confidence_checks/2`'s threshold needs a real answer
  to, not a guess (its own moduledoc: "not empirically calibrated... a
  conservative default pending real data"). See CONTEXT.md's dated entry.
  """
  @spec confidence_calibration([%Result{}]) :: %{grounded: [float()], ungrounded: [float()]}
  def confidence_calibration(results) do
    all = results |> Enum.filter(&is_nil(&1.error)) |> Enum.flat_map(& &1.field_confidences)

    %{
      grounded: all |> Enum.filter(& &1.grounded) |> Enum.map(& &1.confidence),
      ungrounded: all |> Enum.reject(& &1.grounded) |> Enum.map(& &1.confidence)
    }
  end

  @doc "Per document-type, per-bucket decision accuracy."
  @spec bucket_accuracy([%Result{}]) :: %{
          {String.t(), String.t()} => %{total: pos_integer(), correct: non_neg_integer()}
        }
  def bucket_accuracy(results) do
    results
    |> Enum.group_by(&{&1.fixture.document_type_slug, &1.fixture.bucket})
    |> Map.new(fn {key, bucket_results} ->
      correct = Enum.count(bucket_results, &(&1.decision == &1.fixture.expected_decision))
      {key, %{total: length(bucket_results), correct: correct}}
    end)
  end

  @doc """
  Runs the judge tier over completed fixtures with a known expectation.

  A failed judge call (rate limit, transient network error, a malformed
  response that fails `Judge`'s strict JSON parsing) is recorded in
  `:errors`, not silently excluded from the average — an eval harness that
  hides its own failures the same way it exists to catch the agent
  hiding *its* failures would defeat the point.
  """
  @spec judge_scores([%Result{}]) :: %{
          entity_match: %{scores: [float()], errors: [term()]},
          groundedness: %{scores: [float()], errors: [term()]}
        }
  def judge_scores(results) do
    # Entity-match is only meaningful for fixtures with a known expected
    # match/mismatch — today, only `vendor_contract_w9`. Invoice fixtures
    # never set `expected_entity_match`, so this filter naturally excludes
    # them without needing a document-type branch here.
    entity_match =
      results
      |> Enum.filter(fn r ->
        is_nil(r.error) and not is_nil(r.entity_match) and
          not is_nil(r.fixture.expected_entity_match)
      end)
      |> Enum.map(fn r ->
        Judge.entity_match(
          r.fixture.documents["contract"],
          r.fixture.documents["w9"],
          r.entity_match,
          r.fixture.expected_entity_match
        )
      end)
      |> partition_judge_results()

    # Groundedness of a drafted explanation is generic — any document
    # type that halted with an explanation qualifies, not just
    # `vendor_contract_w9`.
    groundedness =
      results
      |> Enum.filter(&(not is_nil(&1.explanation) and not is_nil(&1.findings)))
      |> Enum.map(&Judge.groundedness(&1.findings, &1.explanation))
      |> partition_judge_results()

    %{entity_match: entity_match, groundedness: groundedness}
  end

  defp partition_judge_results(judge_results) do
    {scores, errors} =
      Enum.reduce(judge_results, {[], []}, fn
        {:ok, %{score: score}}, {scores, errors} -> {[score | scores], errors}
        {:error, reason}, {scores, errors} -> {scores, [reason | errors]}
      end)

    %{scores: Enum.reverse(scores), errors: Enum.reverse(errors)}
  end
end
