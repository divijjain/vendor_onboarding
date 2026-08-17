defmodule DocumentComplianceEngine.Agent.Evals.Run do
  @moduledoc """
  Eval harness — drives the reactor directly, bypassing Phoenix, so
  agent-quality eval is isolated from integration latency/correctness
  (CONTEXT.md's evaluation-design decision). Still reads the real
  `vendor_contract_w9` `DocumentType` row (extraction schema + validation
  rules) via `DocumentTypes`, rather than duplicating that config here, so
  the harness can't silently drift from what production actually runs.

  Two tiers:
    - Deterministic (always runs, no judge key needed): Tax ID
      verbatim-in-source, and whether the run completed at all (graceful
      degradation on the malformed bucket).
    - LLM-judge (Claude Sonnet, only if ANTHROPIC_API_KEY is set):
      entity-mapping correctness under formatting variation, and
      groundedness of drafted mismatch explanations.

  The agents themselves need OPENAI_API_KEY regardless of the judge tier.

      mix eval.run
  """

  alias DocumentComplianceEngine.Agent.Evals.{Deterministic, Fixtures, Judge}
  alias DocumentComplianceEngine.Agent.{Checks, DocumentReactor}
  alias DocumentComplianceEngine.DocumentTypes

  @document_type_slug "vendor_contract_w9"

  defmodule Result do
    @moduledoc false
    defstruct [
      :fixture,
      :decision,
      :entity_match,
      :tax_id_verbatim_ok,
      :explanation,
      :findings,
      :error
    ]
  end

  @concurrency 5

  @spec run_all([Fixtures.Fixture.t()], keyword()) :: [%Result{}]
  def run_all(fixtures \\ Fixtures.all(), opts \\ []) do
    reactor = Keyword.get(opts, :reactor, DocumentReactor)
    document_type = Keyword.get_lazy(opts, :document_type, &fetch_document_type!/0)

    fixtures
    # Bounded, not unbounded — 20 fixtures fired at once against a real
    # account risks tripping rate limits for no benefit.
    |> Task.async_stream(&run_fixture(&1, reactor, document_type),
      max_concurrency: Keyword.get(opts, :concurrency, @concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp fetch_document_type! do
    DocumentTypes.get_document_type_by_slug(@document_type_slug) ||
      raise "document type #{@document_type_slug} is not seeded"
  end

  @spec run_fixture(Fixtures.Fixture.t(), module(), DocumentTypes.Schema.DocumentType.t() | nil) ::
          %Result{}
  def run_fixture(fixture, reactor \\ DocumentReactor, document_type \\ nil) do
    document_type = document_type || fetch_document_type!()

    inputs = %{
      document_type_slug: document_type.slug,
      documents: %{"contract" => fixture.contract_text, "w9" => fixture.w9_text},
      extraction_schema: document_type.extraction_schema,
      validation_rules: document_type.validation_rules,
      human_decision: nil
    }

    reactor
    |> Reactor.run(inputs)
    |> to_result(fixture)
  end

  defp to_result({:ok, final}, fixture) do
    tax_id = get_in(final.extracted, ["w9", :tax_id])

    %Result{
      fixture: fixture,
      decision: "approved",
      # Approval requires the entity check to have passed, so it's known
      # true here without re-reading the (completed) validation step.
      entity_match: true,
      tax_id_verbatim_ok: Deterministic.tax_id_verbatim?(tax_id, fixture.w9_text)
    }
  end

  defp to_result({:halted, reactor}, fixture) do
    results = reactor.intermediate_results || %{}
    validation = results[:validate]
    tax_id = get_in(results[:extract] || %{}, ["w9", :tax_id])

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
      tax_id_verbatim_ok: tax_id && Deterministic.tax_id_verbatim?(tax_id, fixture.w9_text),
      explanation: explanation,
      findings: validation && Checks.describe_findings(validation)
    }
  end

  defp to_result({:error, reason}, fixture) do
    # Graceful degradation is itself a measured outcome, not a harness
    # crash — exactly what the malformed bucket tests for.
    %Result{fixture: fixture, error: inspect(reason)}
  end

  @doc "Per-bucket decision accuracy."
  @spec bucket_accuracy([%Result{}]) :: %{
          String.t() => %{total: pos_integer(), correct: non_neg_integer()}
        }
  def bucket_accuracy(results) do
    results
    |> Enum.group_by(& &1.fixture.bucket)
    |> Map.new(fn {bucket, bucket_results} ->
      correct = Enum.count(bucket_results, &(&1.decision == &1.fixture.expected_decision))
      {bucket, %{total: length(bucket_results), correct: correct}}
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
    scorable =
      Enum.filter(results, fn r ->
        is_nil(r.error) and not is_nil(r.entity_match) and
          not is_nil(r.fixture.expected_entity_match)
      end)

    entity_match =
      scorable
      |> Enum.map(fn r ->
        Judge.entity_match(
          r.fixture.contract_text,
          r.fixture.w9_text,
          r.entity_match,
          r.fixture.expected_entity_match
        )
      end)
      |> partition_judge_results()

    groundedness =
      scorable
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
