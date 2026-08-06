"""Proves the harness's own plumbing (fixture -> graph -> scoring/report)
is correct, using injected fake agent calls — not a claim that these fakes
match real GPT-4o-mini/Claude Sonnet behavior. See evals/run.py's docstring:
running the harness for real needs OPENAI_API_KEY (+ ANTHROPIC_API_KEY for
the judge tier), neither of which is configured in this environment.
"""

import re

import evals.judge as judge_module
from app.graph import build_graph
from app.schemas import ContractExtraction, EntityMatchResult, W9Extraction
from evals.fixtures import FIXTURES
from evals.run import bucket_accuracy, run_all, run_judge_tier

_SUFFIXES = {"inc", "llc", "corp", "corporation", "co", "ltd", "group"}
_SYNONYMS = {"tech": "technology"}
_EIN_PATTERN = re.compile(r"^\d{2}-\d{7}$")


def _normalize(name: str) -> set[str]:
    name = name.lower().replace("&", " and ").replace(",", " ")
    tokens = re.findall(r"[a-z0-9]+", name)
    return {_SYNONYMS.get(t, t) for t in tokens if t not in _SUFFIXES}


async def fake_extract_contract(text: str) -> ContractExtraction:
    name = re.search(r'and (.+?) \("Vendor', text).group(1)
    terms = re.search(r"Payment Terms: (.+)", text).group(1)
    liability = re.search(r"Liability: (.+)", text).group(1)
    return ContractExtraction(company_name=name, payment_terms=terms, liability_clauses=liability)


async def fake_extract_w9(text: str) -> W9Extraction:
    name = re.search(r"1\. Name of entity: (.*)", text).group(1)
    tax_id = re.search(r"2\. Taxpayer Identification Number \(EIN\): (.*)", text).group(1)
    return W9Extraction(company_name=name, tax_id=tax_id)


async def fake_entity_match(contract_name: str, w9_name: str) -> EntityMatchResult:
    match = _normalize(contract_name) == _normalize(w9_name)
    return EntityMatchResult(match=match, explanation="fake normalized token-set comparison")


async def fake_validate_tax_id(tax_id: str) -> dict:
    return {"valid": bool(_EIN_PATTERN.match(tax_id.strip()))}


async def fake_screen_vendor(company_name: str) -> dict:
    return {"flagged": False, "reason": None}


async def fake_draft_explanation(findings: str) -> str:
    return f"Explanation: {findings}"


def fake_graph_factory():
    return build_graph(
        extract_contract=fake_extract_contract,
        extract_w9=fake_extract_w9,
        entity_match=fake_entity_match,
        validate_tax_id_fn=fake_validate_tax_id,
        screen_vendor_fn=fake_screen_vendor,
        draft_explanation=fake_draft_explanation,
    )


async def test_run_all_matches_expected_decision_for_every_fixture_with_a_well_behaved_agent():
    results = await run_all(FIXTURES, graph_factory=fake_graph_factory)

    assert len(results) == 20
    for r in results:
        assert r.error is None, f"{r.fixture.id} raised: {r.error}"
        assert r.decision == r.fixture.expected_decision, (
            f"{r.fixture.id}: expected {r.fixture.expected_decision}, got {r.decision}"
        )


async def test_run_all_extracts_tax_id_verbatim_for_well_formed_fixtures():
    results = await run_all(FIXTURES, graph_factory=fake_graph_factory)

    well_formed = [r for r in results if r.fixture.bucket != "malformed"]
    assert well_formed
    assert all(r.tax_id_verbatim_ok for r in well_formed)


async def test_bucket_accuracy_reports_100_percent_when_every_decision_matches_expected():
    results = await run_all(FIXTURES, graph_factory=fake_graph_factory)

    accuracy = bucket_accuracy(results)
    assert accuracy["clean"] == {"total": 10, "decision_correct": 10}
    assert accuracy["mismatch"] == {"total": 5, "decision_correct": 5}
    assert accuracy["formatting"] == {"total": 3, "decision_correct": 3}
    assert accuracy["malformed"] == {"total": 2, "decision_correct": 2}


async def test_run_fixture_handles_a_raising_extractor_as_graceful_degradation_not_a_crash():
    async def boom(text: str) -> ContractExtraction:
        raise ValueError("simulated extraction failure")

    def factory():
        return build_graph(extract_contract=boom)

    results = await run_all([FIXTURES[0]], graph_factory=factory)

    assert results[0].error is not None
    assert "simulated extraction failure" in results[0].error
    assert results[0].decision is None


class _FakeMetric:
    def __init__(self, score: float):
        self._score = score
        self.score = None

    def measure(self, test_case):
        self.score = self._score


async def test_run_judge_tier_scores_only_completed_cases_with_a_known_expectation(monkeypatch):
    monkeypatch.setattr(judge_module, "build_entity_match_metric", lambda: _FakeMetric(0.9))
    monkeypatch.setattr(judge_module, "build_groundedness_metric", lambda: _FakeMetric(0.8))

    results = await run_all(FIXTURES, graph_factory=fake_graph_factory)
    scores = run_judge_tier(results)

    # 18 fixtures have a known expected_entity_match (excludes the 2 malformed).
    assert len(scores["entity_match"]) == 18
    assert all(s == 0.9 for s in scores["entity_match"])
    # groundedness is only scored where an explanation was actually drafted
    # (the mismatch bucket, since the formatting/clean buckets auto-approve).
    assert len(scores["groundedness"]) == 5
    assert all(s == 0.8 for s in scores["groundedness"])
