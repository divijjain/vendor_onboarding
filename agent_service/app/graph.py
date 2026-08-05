"""LangGraph graph for the agent service. Agent 1 (extraction) only for now —
Agent 2 (validation via the MCP tool servers) and the decision/interrupt
branch land in a later build step.
"""

from typing import Callable, Optional, TypedDict

from langgraph.graph import END, StateGraph

from app.schemas import ExtractionResult


class GraphState(TypedDict):
    contract_text: str
    w9_text: str
    extraction: ExtractionResult


ExtractorFn = Callable[[str, str], ExtractionResult]

EXTRACTION_PROMPT = (
    "Extract the company name, tax ID, payment terms, and liability clauses "
    "from the following vendor documents. Use the exact wording from the "
    "source text for the tax ID.\n\nContract:\n{contract_text}\n\nW-9:\n{w9_text}"
)


def default_extractor(contract_text: str, w9_text: str) -> ExtractionResult:
    # Imported lazily so building/testing the graph never requires an
    # OPENAI_API_KEY unless this real extractor path is actually invoked.
    from langchain_openai import ChatOpenAI

    llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)
    structured_llm = llm.with_structured_output(ExtractionResult)

    return structured_llm.invoke(
        EXTRACTION_PROMPT.format(contract_text=contract_text, w9_text=w9_text)
    )


def build_graph(checkpointer=None, extractor: Optional[ExtractorFn] = None):
    extractor = extractor or default_extractor

    def extract_node(state: GraphState) -> dict:
        extraction = extractor(state["contract_text"], state["w9_text"])
        return {"extraction": extraction}

    graph = StateGraph(GraphState)
    graph.add_node("extract", extract_node)
    graph.set_entry_point("extract")
    graph.add_edge("extract", END)

    return graph.compile(checkpointer=checkpointer)
