from fastapi.testclient import TestClient

import app.main as main


def test_trigger_accepts_and_schedules_the_agent_run(monkeypatch):
    calls = []
    monkeypatch.setattr(
        main, "run_agent_run", lambda onboarding_id, document_paths: calls.append(
            (onboarding_id, document_paths)
        )
    )

    client = TestClient(main.app)
    response = client.post(
        "/trigger",
        json={"onboarding_id": 42, "document_paths": {"contract": "c.pdf", "w9": "w.pdf"}},
    )

    assert response.status_code == 202
    assert response.json() == {"accepted": True, "onboarding_id": 42}
    assert calls == [(42, {"contract": "c.pdf", "w9": "w.pdf"})]


def test_run_agent_run_reads_documents_and_sends_the_callback(tmp_path, monkeypatch):
    contract_path = tmp_path / "contract.pdf"
    w9_path = tmp_path / "w9.pdf"
    contract_path.write_text("contract text")
    w9_path.write_text("w9 text")

    from app.schemas import ExtractionResult

    fake_extraction = ExtractionResult(
        company_name="Acme Corp",
        tax_id="12-3456789",
        payment_terms="Net 30",
        liability_clauses="Standard indemnification.",
    )

    class FakeGraph:
        def invoke(self, state, config):
            return {**state, "extraction": fake_extraction}

    monkeypatch.setattr(main, "build_graph", lambda checkpointer=None: FakeGraph())
    monkeypatch.setattr(
        main,
        "get_checkpointer",
        lambda: _NullContextManager(),
    )

    sent = {}
    monkeypatch.setattr(main, "send_callback", lambda payload: sent.update(payload))

    main.run_agent_run(
        7, {"contract": str(contract_path), "w9": str(w9_path)}
    )

    assert sent == {
        "onboarding_id": 7,
        "status": "approved",
        "company_name": "Acme Corp",
        "tax_id": "12-3456789",
        "payment_terms": "Net 30",
        "liability_clauses": "Standard indemnification.",
    }


class _FakeCheckpointer:
    def setup(self):
        pass


class _NullContextManager:
    def __enter__(self):
        return _FakeCheckpointer()

    def __exit__(self, *exc_info):
        return False
