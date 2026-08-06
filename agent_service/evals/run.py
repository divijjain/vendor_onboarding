"""DeepEval harness — calls the LangGraph graph directly, bypassing
Phoenix, so agent-quality eval is isolated from integration-latency/
correctness (CONTEXT.md's evaluation-design decision).

Two tiers:
  - Deterministic (always runs, no judge key needed): Tax ID verbatim-in-
    source check, and whether extraction/validation completed without
    raising at all (graceful degradation on the malformed bucket).
  - LLM-judge (GEval, Claude Sonnet — only runs if ANTHROPIC_API_KEY is
    set): entity-mapping correctness under formatting variation,
    groundedness of drafted mismatch explanations.

The agents themselves (Agent 1 extraction, Agent 2 entity-match) still
need OPENAI_API_KEY regardless of the judge tier — without it every
fixture will error out at the extraction step.

    cd agent_service && uv run python -m evals.run
"""

import asyncio
import os
from dataclasses import dataclass

from dotenv import load_dotenv

from app.graph import build_graph
from evals.deterministic import tax_id_verbatim
from evals.fixtures import FIXTURES, Fixture

load_dotenv()


@dataclass
class FixtureResult:
    fixture: Fixture
    decision: str | None = None
    entity_match: bool | None = None
    tax_id_verbatim_ok: bool | None = None
    explanation: str | None = None
    findings: str | None = None
    error: str | None = None


async def run_fixture(fixture: Fixture, graph_factory=build_graph) -> FixtureResult:
    graph = graph_factory()
    config = {"configurable": {"thread_id": f"eval-{fixture.id}"}}

    try:
        result = await graph.ainvoke(
            {"contract_text": fixture.contract_text, "w9_text": fixture.w9_text}, config
        )
    except Exception as exc:
        # Graceful degradation is itself a measured outcome, not a harness crash —
        # this is exactly what the malformed bucket is testing for.
        return FixtureResult(fixture=fixture, error=f"{type(exc).__name__}: {exc}")

    validation = result.get("validation")
    w9 = result.get("w9_extraction")

    tax_ok = tax_id_verbatim(w9.tax_id, fixture.w9_text) if w9 is not None else None
    entity_match = validation.entity_match.match if validation is not None else None

    if "__interrupt__" in result:
        interrupt_value = result["__interrupt__"][0].value
        decision = "needs_review"
        explanation = interrupt_value["explanation"]
        findings = interrupt_value["reason"]
    else:
        decision = result.get("decision")
        explanation = None
        findings = None

    return FixtureResult(
        fixture=fixture,
        decision=decision,
        entity_match=entity_match,
        tax_id_verbatim_ok=tax_ok,
        explanation=explanation,
        findings=findings,
    )


async def run_all(fixtures: list[Fixture], graph_factory=build_graph) -> list[FixtureResult]:
    return [await run_fixture(f, graph_factory=graph_factory) for f in fixtures]


def bucket_accuracy(results: list[FixtureResult]) -> dict[str, dict[str, int]]:
    by_bucket: dict[str, dict[str, int]] = {}
    for r in results:
        stats = by_bucket.setdefault(r.fixture.bucket, {"total": 0, "decision_correct": 0})
        stats["total"] += 1
        if r.decision == r.fixture.expected_decision:
            stats["decision_correct"] += 1
    return by_bucket


def print_deterministic_report(results: list[FixtureResult]) -> None:
    header = f"{'fixture':<16}{'bucket':<12}{'decision':<14}{'expected':<14}{'entity_match':<14}{'tax_id_ok':<11}error"
    print(header)
    for r in results:
        print(
            f"{r.fixture.id:<16}{r.fixture.bucket:<12}{str(r.decision):<14}"
            f"{r.fixture.expected_decision:<14}{str(r.entity_match):<14}"
            f"{str(r.tax_id_verbatim_ok):<11}{r.error or ''}"
        )

    print()
    for bucket, stats in bucket_accuracy(results).items():
        print(f"{bucket}: decision correct {stats['decision_correct']}/{stats['total']}")


def run_judge_tier(results: list[FixtureResult]) -> dict[str, list[float]]:
    from deepeval.test_case import LLMTestCase

    from evals.judge import build_entity_match_metric, build_groundedness_metric

    entity_metric = build_entity_match_metric()
    groundedness_metric = build_groundedness_metric()
    scores: dict[str, list[float]] = {"entity_match": [], "groundedness": []}

    for r in results:
        if r.error is not None or r.entity_match is None or r.fixture.expected_entity_match is None:
            continue

        entity_metric.measure(
            LLMTestCase(
                input=f"Contract name source:\n{r.fixture.contract_text}\n\nW-9 name source:\n{r.fixture.w9_text}",
                actual_output=f"match={r.entity_match}",
                expected_output=f"match={r.fixture.expected_entity_match}",
            )
        )
        scores["entity_match"].append(entity_metric.score)

        if r.explanation is not None and r.findings is not None:
            groundedness_metric.measure(
                LLMTestCase(
                    input=r.findings,
                    actual_output=r.explanation,
                    context=[r.findings],
                )
            )
            scores["groundedness"].append(groundedness_metric.score)

    return scores


def print_judge_report(scores: dict[str, list[float]]) -> None:
    print("--- LLM-judge tier (Claude Sonnet) ---")
    for name, values in scores.items():
        if values:
            print(f"{name}: avg {sum(values) / len(values):.2f} (n={len(values)})")
        else:
            print(f"{name}: no scored cases")


def main() -> None:
    results = asyncio.run(run_all(FIXTURES))
    print_deterministic_report(results)

    print()
    if os.environ.get("ANTHROPIC_API_KEY"):
        print_judge_report(run_judge_tier(results))
    else:
        print("ANTHROPIC_API_KEY not set -- skipping LLM-judge tier.")


if __name__ == "__main__":
    main()
