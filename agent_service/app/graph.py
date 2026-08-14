"""LangGraph graph for the agent service.

Agent 1: two extraction nodes, one per document — kept separate (not merged
into one call) so Agent 2 has two independent company names to cross-check.
Agent 2: entity-match judgment (LLM, not string equality — see
CONTEXT.md's false-positive eval bucket) plus the two MCP tool calls.
Decision branch: auto-approve, or draft an explanation and `interrupt()`
for human review, checkpointed to Postgres so the pause survives a restart.
"""

from functools import lru_cache
from typing import Awaitable, Callable, Optional, TypedDict

from langgraph.graph import END, StateGraph
from langgraph.types import interrupt

from app.mcp_client import screen_vendor, validate_tax_id
from app.schemas import (
    ContractExtraction,
    EntityMatchResult,
    SanctionsScreeningResult,
    TaxValidationResult,
    ValidationResult,
    W9Extraction,
)


class GraphState(TypedDict, total=False):
    contract_text: str
    w9_text: str
    contract_extraction: ContractExtraction
    w9_extraction: W9Extraction
    validation: ValidationResult
    decision: str
    explanation: str | None


ContractExtractorFn = Callable[[str], Awaitable[ContractExtraction]]
W9ExtractorFn = Callable[[str], Awaitable[W9Extraction]]
EntityMatcherFn = Callable[[str, str], Awaitable[EntityMatchResult]]
TaxIdValidatorFn = Callable[[str], Awaitable[TaxValidationResult]]
VendorScreenerFn = Callable[[str], Awaitable[SanctionsScreeningResult]]
ExplanationDrafterFn = Callable[[str], Awaitable[str]]

CONTRACT_EXTRACTION_PROMPT = (
    "Extract the company name, payment terms, and liability clauses from "
    "the following vendor contract.\n\n{contract_text}"
)

W9_EXTRACTION_PROMPT = (
    "Extract the company name and Tax ID exactly as written from the "
    "following W-9 form.\n\n{w9_text}"
)

ENTITY_MATCH_PROMPT = (
    'Do these two company names refer to the same legal entity? Minor '
    'formatting differences (abbreviations, punctuation, "Corp" vs '
    '"Corporation") are still a match; a genuinely different vendor name '
    "is not.\n\nContract name: {contract_name}\nW-9 name: {w9_name}"
)

EXPLANATION_PROMPT = (
    "Draft a brief, concrete explanation of the discrepancy found while "
    "validating this vendor onboarding, grounded only in the facts below. "
    "Do not invent details.\n\n{findings}"
)


@lru_cache(maxsize=1)
def _default_llm(temperature: float = 0):
    # Cached — every default_extract_*/entity_match/draft_explanation call
    # was constructing a fresh ChatOpenAI client (new HTTP client setup)
    # per call. `.with_structured_output(...)` on top of it is cheap to
    # keep per-call, since it's just a wrapping Runnable, not a new client.
    from langchain_openai import ChatOpenAI

    return ChatOpenAI(model="gpt-4o-mini", temperature=temperature)


async def default_extract_contract(contract_text: str) -> ContractExtraction:
    llm = _default_llm().with_structured_output(ContractExtraction)
    return await llm.ainvoke(CONTRACT_EXTRACTION_PROMPT.format(contract_text=contract_text))


async def default_extract_w9(w9_text: str) -> W9Extraction:
    llm = _default_llm().with_structured_output(W9Extraction)
    return await llm.ainvoke(W9_EXTRACTION_PROMPT.format(w9_text=w9_text))


async def default_entity_match(contract_name: str, w9_name: str) -> EntityMatchResult:
    llm = _default_llm().with_structured_output(EntityMatchResult)
    return await llm.ainvoke(
        ENTITY_MATCH_PROMPT.format(contract_name=contract_name, w9_name=w9_name)
    )


async def default_draft_explanation(findings: str) -> str:
    llm = _default_llm()
    response = await llm.ainvoke(EXPLANATION_PROMPT.format(findings=findings))
    return response.content


def _describe_findings(validation: ValidationResult) -> str:
    findings = []
    if not validation.entity_match.match:
        findings.append(f"Entity name mismatch: {validation.entity_match.explanation}")
    if not validation.tax_id_valid:
        findings.append("Tax ID failed validation against the mock tax registry.")
    if validation.sanctions_flagged:
        findings.append(f"Sanctions screening hit: {validation.sanctions_reason}")
    return "; ".join(findings)


def build_graph(
    checkpointer=None,
    extract_contract: Optional[ContractExtractorFn] = None,
    extract_w9: Optional[W9ExtractorFn] = None,
    entity_match: Optional[EntityMatcherFn] = None,
    validate_tax_id_fn: Optional[TaxIdValidatorFn] = None,
    screen_vendor_fn: Optional[VendorScreenerFn] = None,
    draft_explanation: Optional[ExplanationDrafterFn] = None,
):
    extract_contract = extract_contract or default_extract_contract
    extract_w9 = extract_w9 or default_extract_w9
    entity_match = entity_match or default_entity_match
    validate_tax_id_fn = validate_tax_id_fn or validate_tax_id
    screen_vendor_fn = screen_vendor_fn or screen_vendor
    draft_explanation = draft_explanation or default_draft_explanation

    async def extract_contract_node(state: GraphState) -> dict:
        return {"contract_extraction": await extract_contract(state["contract_text"])}

    async def extract_w9_node(state: GraphState) -> dict:
        return {"w9_extraction": await extract_w9(state["w9_text"])}

    async def validate_node(state: GraphState) -> dict:
        contract = state["contract_extraction"]
        w9 = state["w9_extraction"]

        match_result = await entity_match(contract.company_name, w9.company_name)
        tax_result = await validate_tax_id_fn(w9.tax_id)
        sanctions_result = await screen_vendor_fn(contract.company_name)

        validation = ValidationResult(
            entity_match=match_result,
            tax_id_valid=tax_result.valid,
            sanctions_flagged=sanctions_result.flagged,
            sanctions_reason=sanctions_result.reason,
        )
        return {"validation": validation}

    def route_decision(state: GraphState) -> str:
        return "approve" if state["validation"].approved else "flag_for_review"

    async def approve_node(state: GraphState) -> dict:
        return {"decision": "approved"}

    async def flag_for_review_node(state: GraphState) -> dict:
        validation = state["validation"]
        findings = _describe_findings(validation)
        explanation = await draft_explanation(findings)

        review_decision = interrupt(
            {
                "reason": findings,
                "explanation": explanation,
                "contract_extraction": state["contract_extraction"].model_dump(),
                "w9_extraction": state["w9_extraction"].model_dump(),
            }
        )

        return {"decision": review_decision, "explanation": explanation}

    graph = StateGraph(GraphState)
    graph.add_node("extract_contract", extract_contract_node)
    graph.add_node("extract_w9", extract_w9_node)
    graph.add_node("validate", validate_node)
    graph.add_node("approve", approve_node)
    graph.add_node("flag_for_review", flag_for_review_node)

    graph.set_entry_point("extract_contract")
    graph.add_edge("extract_contract", "extract_w9")
    graph.add_edge("extract_w9", "validate")
    graph.add_conditional_edges(
        "validate",
        route_decision,
        {"approve": "approve", "flag_for_review": "flag_for_review"},
    )
    graph.add_edge("approve", END)
    graph.add_edge("flag_for_review", END)

    return graph.compile(checkpointer=checkpointer)
