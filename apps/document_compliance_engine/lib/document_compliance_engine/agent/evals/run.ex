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
  one pass.

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

  defmodule Result do
    @moduledoc false
    defstruct [
      :fixture,
      :decision,
      :entity_match,
      :tax_id_verbatim_ok,
      :fields_grounded,
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

    inputs = %{
      document_type_slug: fixture.document_type_slug,
      documents: fixture.documents,
      extraction_schema: document_type.extraction_schema,
      validation_rules: document_type.validation_rules,
      shape_signals: document_type.shape_signals,
      human_decision: nil
    }

    reactor
    |> Reactor.run(inputs)
    |> to_result(fixture, document_type)
  end

  defp to_result({:ok, final}, fixture, document_type) do
    tax_id = get_in(final.extracted, ["w9", :tax_id])

    %Result{
      fixture: fixture,
      decision: "approved",
      # Approval requires every configured rule to have passed, so an
      # entity_match rule (when this type has one) is known true here
      # without re-reading the (completed) validation step.
      entity_match: if(fixture.expected_entity_match != nil, do: true),
      tax_id_verbatim_ok: tax_id_verbatim_ok(fixture, tax_id),
      fields_grounded: fields_grounded?(final.extracted, fixture, document_type)
    }
  end

  defp to_result({:halted, reactor}, fixture, document_type) do
    results = reactor.intermediate_results || %{}
    validation = results[:validate]
    extract_result = results[:extract] || %{}
    extracted = extract_result[:fields] || %{}
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
      tax_id_verbatim_ok: tax_id_verbatim_ok(fixture, tax_id),
      fields_grounded: fields_grounded?(extracted, fixture, document_type),
      explanation: explanation,
      findings: validation && Checks.describe_findings(validation)
    }
  end

  defp to_result({:error, reason}, fixture, _document_type) do
    # Graceful degradation is itself a measured outcome, not a harness
    # crash — exactly what the malformed buckets test for.
    %Result{fixture: fixture, error: inspect(reason)}
  end

  defp tax_id_verbatim_ok(fixture, tax_id) do
    case Map.get(fixture.documents, "w9") do
      nil -> nil
      w9_text -> Deterministic.tax_id_verbatim?(tax_id, w9_text)
    end
  end

  defp fields_grounded?(extracted, fixture, document_type) do
    Deterministic.fields_grounded?(extracted, fixture.documents, document_type.shape_signals)
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
