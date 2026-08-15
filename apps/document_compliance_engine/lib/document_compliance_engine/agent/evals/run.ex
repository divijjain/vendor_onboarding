defmodule DocumentComplianceEngine.Agent.Evals.Run do
  @moduledoc """
  Eval harness — drives the reactor directly, bypassing Phoenix, so
  agent-quality eval is isolated from integration latency/correctness
  (CONTEXT.md's evaluation-design decision).

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
  alias DocumentComplianceEngine.Agent.OnboardingReactor

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
    reactor = Keyword.get(opts, :reactor, OnboardingReactor)

    fixtures
    # Bounded, not unbounded — 20 fixtures fired at once against a real
    # account risks tripping rate limits for no benefit.
    |> Task.async_stream(&run_fixture(&1, reactor),
      max_concurrency: Keyword.get(opts, :concurrency, @concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  @spec run_fixture(Fixtures.Fixture.t(), module()) :: %Result{}
  def run_fixture(fixture, reactor \\ OnboardingReactor) do
    inputs = %{
      contract_text: fixture.contract_text,
      w9_text: fixture.w9_text,
      human_decision: nil
    }

    reactor
    |> Reactor.run(inputs)
    |> to_result(fixture)
  end

  defp to_result({:ok, final}, fixture) do
    %Result{
      fixture: fixture,
      decision: "approved",
      # Approval requires the entity check to have passed, so it's known
      # true here without re-reading the (completed) validation step.
      entity_match: true,
      tax_id_verbatim_ok: Deterministic.tax_id_verbatim?(final.w9.tax_id, fixture.w9_text)
    }
  end

  defp to_result({:halted, reactor}, fixture) do
    results = reactor.intermediate_results || %{}
    validation = results[:validate]
    w9 = results[:extract_w9]

    explanation =
      case results[:gate] do
        {:awaiting_human, explanation} -> explanation
        _ -> nil
      end

    %Result{
      fixture: fixture,
      decision: "needs_review",
      entity_match: validation && validation.entity_match.match,
      tax_id_verbatim_ok: w9 && Deterministic.tax_id_verbatim?(w9.tax_id, fixture.w9_text),
      explanation: explanation,
      findings: validation && DocumentComplianceEngine.Agent.Checks.describe_findings(validation)
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

  @doc "Runs the judge tier over completed fixtures with a known expectation."
  @spec judge_scores([%Result{}]) :: %{entity_match: [float()], groundedness: [float()]}
  def judge_scores(results) do
    scorable =
      Enum.filter(results, fn r ->
        is_nil(r.error) and not is_nil(r.entity_match) and
          not is_nil(r.fixture.expected_entity_match)
      end)

    entity_scores =
      for r <- scorable,
          {:ok, %{score: score}} <-
            [
              Judge.entity_match(
                r.fixture.contract_text,
                r.fixture.w9_text,
                r.entity_match,
                r.fixture.expected_entity_match
              )
            ],
          do: score

    groundedness_scores =
      for r <- scorable,
          not is_nil(r.explanation),
          not is_nil(r.findings),
          {:ok, %{score: score}} <- [Judge.groundedness(r.findings, r.explanation)],
          do: score

    %{entity_match: entity_scores, groundedness: groundedness_scores}
  end
end
