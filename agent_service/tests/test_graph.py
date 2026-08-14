from langgraph.types import Command

from app.checkpointer import get_checkpointer
from app.graph import build_graph
from app.schemas import (
    ContractExtraction,
    EntityMatchResult,
    SanctionsScreeningResult,
    TaxValidationResult,
    W9Extraction,
)


async def fake_extract_contract(contract_text: str) -> ContractExtraction:
    return ContractExtraction(
        company_name="Acme Corp", payment_terms="Net 30", liability_clauses="Standard."
    )


async def fake_extract_w9_matching(w9_text: str) -> W9Extraction:
    return W9Extraction(company_name="Acme Corp", tax_id="12-3456789")


async def fake_extract_w9_mismatched(w9_text: str) -> W9Extraction:
    return W9Extraction(company_name="Totally Different LLC", tax_id="12-3456789")


async def fake_entity_match(contract_name: str, w9_name: str) -> EntityMatchResult:
    match = contract_name.strip().lower() == w9_name.strip().lower()
    return EntityMatchResult(match=match, explanation="fake exact-string comparison")


async def fake_validate_tax_id_valid(tax_id: str) -> TaxValidationResult:
    return TaxValidationResult(valid=True)


async def fake_validate_tax_id_invalid(tax_id: str) -> TaxValidationResult:
    return TaxValidationResult(valid=False)


async def fake_screen_vendor_clean(company_name: str) -> SanctionsScreeningResult:
    return SanctionsScreeningResult(flagged=False, reason=None)


async def fake_screen_vendor_flagged(company_name: str) -> SanctionsScreeningResult:
    return SanctionsScreeningResult(flagged=True, reason="Matched sanctions watchlist entry")


async def fake_draft_explanation(findings: str) -> str:
    return f"Explanation: {findings}"


def _build(**overrides):
    defaults = dict(
        extract_contract=fake_extract_contract,
        extract_w9=fake_extract_w9_matching,
        entity_match=fake_entity_match,
        validate_tax_id_fn=fake_validate_tax_id_valid,
        screen_vendor_fn=fake_screen_vendor_clean,
        draft_explanation=fake_draft_explanation,
    )
    defaults.update(overrides)
    return build_graph(**defaults)


async def test_auto_approves_when_everything_matches_and_validates():
    graph = _build()

    result = await graph.ainvoke({"contract_text": "c", "w9_text": "w"})

    assert result["decision"] == "approved"
    assert "__interrupt__" not in result


async def test_flags_for_review_on_entity_name_mismatch():
    graph = _build(extract_w9=fake_extract_w9_mismatched)

    result = await graph.ainvoke({"contract_text": "c", "w9_text": "w"})

    assert "__interrupt__" in result
    interrupt_value = result["__interrupt__"][0].value
    assert "Entity name mismatch" in interrupt_value["reason"]


async def test_flags_for_review_on_invalid_tax_id():
    graph = _build(validate_tax_id_fn=fake_validate_tax_id_invalid)

    result = await graph.ainvoke({"contract_text": "c", "w9_text": "w"})

    assert "__interrupt__" in result
    assert "Tax ID failed validation" in result["__interrupt__"][0].value["reason"]


async def test_flags_for_review_on_sanctions_hit():
    graph = _build(screen_vendor_fn=fake_screen_vendor_flagged)

    result = await graph.ainvoke({"contract_text": "c", "w9_text": "w"})

    assert "__interrupt__" in result
    assert "Sanctions screening hit" in result["__interrupt__"][0].value["reason"]


async def test_interrupt_persists_and_resumes_via_the_real_postgres_checkpointer():
    # Exercises the real local Postgres checkpointer (own `langgraph` schema)
    # per CONTEXT.md's "wire the checkpointer even though nothing pauses yet"
    # and the durable-pause claim the whole project is built around.
    async with get_checkpointer() as checkpointer:
        await checkpointer.setup()
        graph = _build(
            checkpointer=checkpointer, extract_w9=fake_extract_w9_mismatched
        )
        config = {"configurable": {"thread_id": "test-thread-validation-interrupt"}}

        paused = await graph.ainvoke({"contract_text": "c", "w9_text": "w"}, config)
        assert "__interrupt__" in paused

        state = await graph.aget_state(config)
        assert state.next == ("flag_for_review",)

        resumed = await graph.ainvoke(Command(resume="approved"), config)
        assert resumed["decision"] == "approved"
        assert "__interrupt__" not in resumed
