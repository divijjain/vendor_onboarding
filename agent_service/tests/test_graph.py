from app.graph import build_graph
from app.checkpointer import get_checkpointer
from app.schemas import ExtractionResult


def fake_extractor(contract_text: str, w9_text: str) -> ExtractionResult:
    return ExtractionResult(
        company_name="Acme Corp",
        tax_id="12-3456789",
        payment_terms="Net 30",
        liability_clauses="Standard indemnification clause.",
    )


def test_build_graph_runs_the_extraction_node_without_a_checkpointer():
    graph = build_graph(extractor=fake_extractor)

    result = graph.invoke({"contract_text": "contract", "w9_text": "w9"})

    assert result["extraction"] == fake_extractor("contract", "w9")


def test_build_graph_persists_state_via_the_postgres_checkpointer():
    # Exercises the real local Postgres checkpointer (own `langgraph` schema)
    # per CONTEXT.md's "wire the checkpointer even though nothing pauses yet."
    with get_checkpointer() as checkpointer:
        checkpointer.setup()
        graph = build_graph(checkpointer=checkpointer, extractor=fake_extractor)
        config = {"configurable": {"thread_id": "test-thread-graph-checkpoint"}}

        graph.invoke({"contract_text": "contract", "w9_text": "w9"}, config)

        state = graph.get_state(config)
        assert state.values["extraction"] == fake_extractor("contract", "w9")
